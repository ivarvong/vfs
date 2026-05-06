defmodule VFS.Integration.CloudflareArtifactsTest do
  @moduledoc """
  End-to-end agent-loop persistence demo against real Cloudflare Artifacts.

  This is the **rehydration story** — the durable backing for an agent
  loop:

    1. *artifact provisioning* — call the CF Artifacts management API to
       create a fresh repo and mint a write-scoped bearer token.
    2. *boot* — push initial state to a `main` branch on the new repo.
    3. *agent session 1* — clone the repo, mount it via
       `Exgit.Workspace` into a `%VFS{}` next to a `VFS.Memory` scratch.
       Read and write files through the unified `VFS` surface, commit,
       push back to CF, then drop **all** in-memory state.
    4. *rehydrate* — fresh clone of the same repo into a brand-new
       repo value with no shared object cache or process state. Mount,
       read through VFS, and verify session 1's writes persisted.
    5. *cleanup* — delete the test repo via the management API.

  If session 2 sees session 1's edits, the artifact-backed agent loop
  works: durable state lives on Cloudflare, the agent process is
  fungible.

  Each network operation is timed and printed (`mix test --include
  integration_network test/integration/cloudflare_artifacts_test.exs`
  to see the numbers).

  Tagged `:integration_network` and `:cloudflare`. Self-skips when the
  CF management env vars (`CF_API_TOKEN`, `CF_ACCOUNT_ID`) are missing.
  """
  use ExUnit.Case, async: false

  alias Exgit.CloudflareArtifacts
  alias Exgit.CloudflareArtifacts.{Repo, Token}
  alias Exgit.Object.{Blob, Commit, Tree}
  alias Exgit.{ObjectStore, RefStore, Repository, Transport, Workspace}

  @moduletag :integration_network
  @moduletag :cloudflare
  @moduletag timeout: 120_000

  @namespace "default"

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

      repo_name = "vfs-rehydrate-#{System.system_time(:millisecond)}-#{rand_suffix()}"

      on_exit(fn ->
        _ = CloudflareArtifacts.delete_repo(client, repo_name)
      end)

      {:ok, skip: false, client: client, repo_name: repo_name}
    end
  end

  test "full lifecycle: provision artifact → boot → commit → pause → rehydrate", ctx do
    if Map.get(ctx, :skip) do
      assert true, "skipped: CF_API_TOKEN / CF_ACCOUNT_ID not set"
    else
      run_demo(ctx)
    end
  end

  defp run_demo(ctx) do
    %{client: client, repo_name: repo_name} = ctx

    timings = %{}

    # ── Phase 0: provision artifact via management API ──────────────
    {timings, %Repo{remote: git_url}} =
      timed(timings, :create_repo, fn ->
        {:ok, repo} =
          CloudflareArtifacts.create_repo(client,
            name: repo_name,
            default_branch: "main",
            description: "vfs rehydration smoketest"
          )

        repo
      end)

    {timings, %Token{plaintext: write_token}} =
      timed(timings, :mint_token, fn ->
        {:ok, tok} =
          CloudflareArtifacts.create_token(client, repo: repo_name, scope: :write, ttl: 600)

        tok
      end)

    transport = transport(git_url, write_token)
    ref = "refs/heads/main"
    remote_ref = "refs/remotes/origin/main"

    # ── Phase 1: seed initial state on CF ───────────────────────────
    {seed_repo, seed_sha} = build_seed_commit()
    {:ok, seed_repo} = put_ref(seed_repo, ref, seed_sha)

    {timings, _} =
      timed(timings, :push_seed, fn ->
        {:ok, _} = Exgit.push(seed_repo, transport, refspecs: [ref])
      end)

    # ── Phase 2: "agent boots" — fresh clone, mount via VFS ─────────
    {timings, agent1_repo} =
      timed(timings, :clone_boot, fn ->
        {:ok, repo} = Exgit.clone(transport)
        assert repo.mode == :eager
        repo
      end)

    fs1 =
      VFS.new()
      |> VFS.mount("/repo", Workspace.open(agent1_repo, remote_ref))
      |> VFS.mount("/scratch", VFS.Memory.new())

    # See seeded state through the unified VFS surface.
    {:ok, "# seed\n", fs1} = VFS.read_file(fs1, "/repo/README.md")
    {:ok, "{\"v\":1}\n", fs1} = VFS.read_file(fs1, "/repo/config.json")

    # Per-turn ephemeral scratch alongside durable repo state.
    {:ok, fs1} = VFS.write_file(fs1, "/scratch/plan.md", "modify README, add notes\n")
    {:ok, "modify README, add notes\n", fs1} = VFS.read_file(fs1, "/scratch/plan.md")

    # Agent mutates the working tree through VFS.
    new_readme = "# seed\n\n# touched by agent 1\n"
    notes = "agent 1 was here\n"
    {:ok, fs1} = VFS.write_file(fs1, "/repo/README.md", new_readme)
    {:ok, fs1} = VFS.write_file(fs1, "/repo/notes.md", notes)
    {:ok, ^new_readme, fs1} = VFS.read_file(fs1, "/repo/README.md")
    {:ok, ^notes, fs1} = VFS.read_file(fs1, "/repo/notes.md")

    # Commit through Workspace, push to CF.
    ws = workspace_from(fs1, "/repo")

    {:ok, [{:modified, "README.md"}, {:added, "notes.md"}], ws} = sorted_diff(ws)

    {:ok, _commit_sha, ws} =
      Workspace.commit(ws,
        message: "agent 1 turn",
        author: %{name: "vfs-test", email: "test@example.com"},
        update_ref: ref
      )

    {timings, _} =
      timed(timings, :push_modified, fn ->
        {:ok, _} = Exgit.push(ws.repo, transport, refspecs: [ref])
      end)

    # ── Phase 3: "pause" — drop ALL agent-1 state ───────────────────
    fs1 = nil
    ws = nil
    agent1_repo = nil
    _ = {fs1, ws, agent1_repo}

    # ── Phase 4: "rehydrate" — fresh clone, fresh mount, verify ─────
    {timings, agent2_repo} =
      timed(timings, :clone_rehydrate, fn ->
        {:ok, repo} = Exgit.clone(transport)
        repo
      end)

    refute identical_repos?(agent2_repo, seed_repo)

    fs2 =
      VFS.new()
      |> VFS.mount("/repo", Workspace.open(agent2_repo, remote_ref))
      |> VFS.mount("/scratch", VFS.Memory.new())

    {:ok, ^new_readme, fs2} = VFS.read_file(fs2, "/repo/README.md")
    {:ok, ^notes, fs2} = VFS.read_file(fs2, "/repo/notes.md")
    {:ok, "{\"v\":1}\n", fs2} = VFS.read_file(fs2, "/repo/config.json")

    {:ok, names, fs2} = VFS.readdir(fs2, "/repo")
    assert Enum.sort(Enum.to_list(names)) == ["README.md", "config.json", "notes.md"]

    assert {:error, %VFS.Error{kind: :enoent}} = VFS.read_file(fs2, "/scratch/plan.md")

    # ── Phase 5: cleanup is in on_exit; time it here for the report. ─
    {timings, _} =
      timed(timings, :delete_repo, fn ->
        {:ok, _} = CloudflareArtifacts.delete_repo(client, repo_name)
      end)

    print_timings(timings, repo_name)
  end

  # ── timing ─────────────────────────────────────────────────────────

  defp timed(map, label, fun) do
    {micros, result} = :timer.tc(fun)
    {Map.put(map, label, micros / 1000), result}
  end

  @timing_order [
    :create_repo,
    :mint_token,
    :push_seed,
    :clone_boot,
    :push_modified,
    :clone_rehydrate,
    :delete_repo
  ]

  defp print_timings(timings, repo_name) do
    total = @timing_order |> Enum.map(&Map.fetch!(timings, &1)) |> Enum.sum()
    payload = build_payload(timings, repo_name, total)

    case System.get_env("CF_BENCH_LOG") do
      nil -> print_human(payload)
      "" -> print_human(payload)
      path -> append_jsonl(path, payload)
    end
  end

  defp build_payload(timings, repo_name, total) do
    %{
      ts: DateTime.utc_now() |> DateTime.to_iso8601(),
      repo: repo_name,
      total_ms: round_ms(total),
      ops: Map.new(@timing_order, fn op -> {op, round_ms(Map.fetch!(timings, op))} end)
    }
  end

  defp print_human(%{repo: repo_name, total_ms: total, ops: ops}) do
    IO.puts("\n  CF artifacts lifecycle for #{repo_name}:")

    for op <- @timing_order do
      ms = Map.fetch!(ops, op)
      IO.puts("    #{String.pad_trailing(to_string(op), 18)} #{:io_lib.format(~c"~7.1f", [ms])} ms")
    end

    IO.puts("    #{String.pad_trailing("total", 18)} #{:io_lib.format(~c"~7.1f", [total])} ms\n")
  end

  defp append_jsonl(path, payload) do
    line = Jason.encode!(payload) <> "\n"
    File.write!(path, line, [:append])
  end

  defp round_ms(ms), do: Float.round(ms, 1)

  # ── helpers ────────────────────────────────────────────────────────

  defp transport(url, tok),
    do: Transport.HTTP.new(url, auth: {:bearer, tok}, redirect: :same_origin)

  defp empty_repo do
    %Repository{
      object_store: ObjectStore.Memory.new(),
      ref_store: RefStore.Memory.new(),
      config: Exgit.Config.new(),
      path: nil
    }
  end

  defp build_seed_commit do
    repo = empty_repo()
    {repo, readme_sha} = put_blob(repo, "# seed\n")
    {repo, cfg_sha} = put_blob(repo, "{\"v\":1}\n")

    tree =
      Tree.new([
        {"100644", "README.md", readme_sha},
        {"100644", "config.json", cfg_sha}
      ])

    {repo, tree_sha} = put_object(repo, tree)

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

  defp put_blob(repo, content), do: put_object(repo, Blob.new(content))

  defp put_object(repo, object) do
    {:ok, sha, store} = ObjectStore.put(repo.object_store, object)
    {%{repo | object_store: store}, sha}
  end

  defp put_ref(repo, name, sha) do
    {:ok, ref_store} = RefStore.write(repo.ref_store, name, sha, [])
    {:ok, %{repo | ref_store: ref_store}}
  end

  defp workspace_from(%VFS{} = fs, mountpoint) do
    {^mountpoint, %Workspace{} = ws} = List.keyfind(VFS.mounts(fs), mountpoint, 0)
    ws
  end

  defp sorted_diff(ws) do
    case Workspace.diff(ws) do
      {:ok, changes, ws} -> {:ok, Enum.sort_by(changes, &elem(&1, 1)), ws}
      other -> other
    end
  end

  defp identical_repos?(%Repository{object_store: a}, %Repository{object_store: b}), do: a == b

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp rand_suffix, do: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
end
