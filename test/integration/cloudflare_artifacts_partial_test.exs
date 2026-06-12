defmodule VFS.Integration.CloudflareArtifactsPartialCloneTest do
  @moduledoc """
  Third variant of the CF Artifacts agent-loop demo, focused on the
  **bounded-fungibility property**: can an agent boot against an
  artifact-backed repo with size-of-history independent of repo size?

  Same lifecycle skeleton as `cloudflare_artifacts_test.exs`, but the
  rehydrate clone uses **`filter: {:blob, :none}`** — git protocol v2
  partial-clone capability. The server is asked to ship refs +
  commits + trees but omit all blob bytes; missing blobs are fetched
  on demand via `Promisor.resolve/2` the first time the agent reads
  them.

  This is a **probe test**: it asks CF Artifacts a yes/no question.

    * SUCCESS (server advertises `filter`) — clone returns a lazy
      promisor repo, the agent's first read of each file triggers
      exactly one `fetch_and_cache` span, and subsequent reads of
      the same file are cache hits. This is the property the
      "agent boots in bounded time regardless of repo size" pitch
      depends on.

    * UNSUPPORTED — clone returns `{:error, {:filter_unsupported,
      caps}}`. Test fails with the server's advertised fetch caps
      attached. That failure is itself the finding to report:
      blobless clones aren't an option against CF today; agents on
      large repos need shallow clones or aggressive checkpoint
      squashing instead.

  ## Current status

  As of the last run, CF's fetch endpoint advertises only
  `["shallow"]` — no `filter` capability. This test is therefore
  tagged `:known_limitation` (not `:integration_network`) so the
  regular `--include integration_network` opt-in stays clean. To
  re-probe CF for capability changes:

      mix test --include known_limitation \\
               test/integration/cloudflare_artifacts_partial_test.exs

  When CF lands `filter` support, the test will go green; at that
  point, drop `:known_limitation` and add `:integration_network`
  so it joins the regular network-smoke suite.

  The seed deliberately contains files of varying sizes so the
  per-blob fetch behavior is visible in telemetry when the
  capability does land.
  """
  use ExUnit.Case, async: false

  alias Exgit.CloudflareArtifacts
  alias Exgit.CloudflareArtifacts.{Repo, Token}
  alias Exgit.Object.{Blob, Commit, Tree}
  alias Exgit.{ObjectStore, RefStore, Repository, Transport, Workspace}

  @moduletag :cloudflare
  @moduletag :known_limitation
  @moduletag timeout: 120_000

  @namespace "default"

  # Files used in the seed. Varied sizes so per-blob fetch behavior
  # is observable; the largest must be big enough that a blobless
  # vs. full clone is a meaningful pack-size difference.
  @seed_files [
    {"README.md", "# big repo\n"},
    {"config.json", "{\"v\":1}\n"},
    {"src.txt", :crypto.strong_rand_bytes(1_024) |> Base.encode16()},
    {"data.txt", :crypto.strong_rand_bytes(16_384) |> Base.encode16()}
  ]

  setup_all do
    api_token = System.get_env("CF_API_TOKEN")
    account_id = System.get_env("CF_ACCOUNT_ID")

    if blank?(api_token) or blank?(account_id) do
      {:ok, skip: true}
    else
      client =
        CloudflareArtifacts.new(
          account_id: account_id,
          namespace: @namespace,
          api_token: api_token
        )

      repo_name = "vfs-partial-#{System.system_time(:millisecond)}-#{rand_suffix()}"

      on_exit(fn ->
        _ = CloudflareArtifacts.delete_repo(client, repo_name)
      end)

      {:ok, skip: false, client: client, repo_name: repo_name}
    end
  end

  test "rehydrate via filter=blob:none — blobs fetched on demand", ctx do
    if Map.get(ctx, :skip) do
      assert true, "skipped: CF_API_TOKEN / CF_ACCOUNT_ID not set"
    else
      run_probe(ctx)
    end
  end

  defp run_probe(%{client: client, repo_name: repo_name}) do
    # ── Phase 0: provision via management API ──────────────────────
    {:ok, %Repo{remote: git_url}} =
      CloudflareArtifacts.create_repo(client,
        name: repo_name,
        default_branch: "main",
        description: "vfs partial-clone probe"
      )

    {:ok, %Token{plaintext: token}} =
      CloudflareArtifacts.create_token(client, repo: repo_name, scope: :write, ttl: 600)

    transport = Transport.HTTP.new(git_url, auth: {:bearer, token}, redirect: :same_origin)
    ref = "refs/heads/main"
    remote_ref = "refs/remotes/origin/main"

    # ── Phase 1: seed initial state (full, pure-Elixir, in-memory) ─
    {seed_repo, seed_sha} = build_seed_commit(@seed_files)
    {:ok, seed_repo} = put_ref(seed_repo, ref, seed_sha)
    {:ok, _} = Exgit.push(seed_repo, transport, refspecs: [ref])

    # Drop seed state.
    _ = seed_repo

    # ── Phase 2: rehydrate via partial clone — the probe. ──────────
    {clone_micros, clone_result} =
      :timer.tc(fn ->
        Exgit.clone(transport, filter: {:blob, :none}, if_unsupported: :error)
      end)

    case clone_result do
      {:error, {:filter_unsupported, caps}} ->
        flunk("""
        CF Artifacts did not advertise the git protocol v2 `filter`
        capability on the fetch endpoint. Blobless clones are not
        available; agents on large repos cannot use this path.

        Server-advertised fetch capabilities:
        #{inspect(caps, pretty: true)}
        """)

      {:ok, repo} ->
        assert repo.mode == :lazy,
               "expected :lazy mode after filter clone, got #{inspect(repo.mode)}"

        run_lazy_assertions(repo, remote_ref, clone_micros / 1000)
    end

    # ── Phase 3: cleanup ───────────────────────────────────────────
    {:ok, _} = CloudflareArtifacts.delete_repo(client, repo_name)
  end

  defp run_lazy_assertions(repo, remote_ref, clone_ms) do
    {test_pid, handler_id} = attach_fetch_counter()

    try do
      fs = VFS.new() |> VFS.mount("/repo", Workspace.open(repo, remote_ref))

      # First read of README.md → exactly one blob fetched.
      {:ok, "# big repo\n", fs} = VFS.read_file(fs, "/repo/README.md")
      first_readme = drain_fetches(test_pid)
      assert first_readme != [], "first read should fetch ≥1 blob"

      # Re-read the same file → cache hit, no additional fetch.
      {:ok, "# big repo\n", fs} = VFS.read_file(fs, "/repo/README.md")
      reread_readme = drain_fetches(test_pid)

      assert reread_readme == [],
             "re-read should hit cache, but observed fetches: #{inspect(reread_readme)}"

      # Read a different file → another fetch.
      {:ok, _, fs} = VFS.read_file(fs, "/repo/data.txt")
      first_data = drain_fetches(test_pid)
      assert first_data != [], "first read of new file should fetch"

      # config.json is small but still a blob — same story.
      {:ok, "{\"v\":1}\n", _fs} = VFS.read_file(fs, "/repo/config.json")
      first_config = drain_fetches(test_pid)
      assert first_config != [], "first read of config should fetch"

      print_report(%{
        clone_ms: clone_ms,
        first_readme: length(first_readme),
        reread_readme: length(reread_readme),
        first_data: length(first_data),
        first_config: length(first_config)
      })
    after
      :telemetry.detach(handler_id)
    end
  end

  # ── telemetry probe ────────────────────────────────────────────────

  defp attach_fetch_counter do
    test_pid = self()
    handler_id = "cf-partial-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:exgit, :object_store, :fetch_and_cache, :stop],
      fn _event, _measurements, %{sha: sha}, _config ->
        send(test_pid, {:fetch, sha})
      end,
      nil
    )

    {test_pid, handler_id}
  end

  defp drain_fetches(_pid) do
    receive do
      {:fetch, sha} -> [sha | drain_fetches(nil)]
    after
      0 -> []
    end
  end

  defp print_report(stats) do
    IO.puts("""

      CF artifacts PARTIAL-CLONE probe:
        clone(filter: {:blob, :none})  #{:io_lib.format(~c"~7.1f", [stats.clone_ms])} ms
        read README.md  (first)         #{stats.first_readme} fetch event(s)
        read README.md  (cached)        #{stats.reread_readme} fetch event(s)
        read data.txt   (first)         #{stats.first_data} fetch event(s)
        read config.json (first)        #{stats.first_config} fetch event(s)
    """)
  end

  # ── seed helpers (pure Elixir, no git binary) ──────────────────────

  defp build_seed_commit(files) do
    repo = empty_repo()

    {repo, tree_entries} =
      Enum.reduce(files, {repo, []}, fn {name, content}, {repo, acc} ->
        {repo, sha} = put_object(repo, Blob.new(content))
        {repo, [{"100644", name, sha} | acc]}
      end)

    {repo, tree_sha} = put_object(repo, Tree.new(Enum.reverse(tree_entries)))

    commit =
      Commit.new(
        tree: tree_sha,
        parents: [],
        author: "vfs-test <test@example.com> 1700000000 +0000",
        committer: "vfs-test <test@example.com> 1700000000 +0000",
        message: "seed\n"
      )

    {repo, commit_sha} = put_object(repo, commit)
    {repo, commit_sha}
  end

  defp empty_repo do
    %Repository{
      object_store: ObjectStore.Memory.new(),
      ref_store: RefStore.Memory.new(),
      config: Exgit.Config.new(),
      path: nil
    }
  end

  defp put_object(repo, object) do
    {:ok, sha, store} = ObjectStore.put(repo.object_store, object)
    {%{repo | object_store: store}, sha}
  end

  defp put_ref(repo, name, sha) do
    {:ok, ref_store} = RefStore.write(repo.ref_store, name, sha, [])
    {:ok, %{repo | ref_store: ref_store}}
  end

  # ── misc ───────────────────────────────────────────────────────────

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp rand_suffix, do: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
end
