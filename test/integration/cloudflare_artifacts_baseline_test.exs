defmodule VFS.Integration.CloudflareArtifactsBaselineTest do
  @moduledoc """
  Baseline counterpart to `cloudflare_artifacts_test.exs`.

  Same end-to-end lifecycle — provision a CF repo, seed it, "agent 1"
  clones / edits / commits / pushes / drops state, "agent 2"
  fresh-clones and reads the writes back — but with the **`git`
  binary + temp folders + `File.read!`/`File.write!`**. No exgit, no
  VFS, no protocol, no mount table. The CF Artifacts control plane
  (`create_repo`, `create_token`, `delete_repo`) is HTTP either way
  and reuses the existing management client.

  Read alongside `cloudflare_artifacts_test.exs` to see what the
  heavy machinery actually buys you. Both pass; both prove the
  rehydration story.

  Where this baseline holds up:
    * Any runtime with a `git` binary, a writable tmpdir, one agent
      session per OS process.

  Where it doesn't:
    * No-binary sandboxes (Workers, Lambda) — nothing to shell out to.
    * Many concurrent in-process sessions — N temp folders, N cwds,
      no shared object cache.
    * Composing git state with non-git mounts (ephemeral scratch,
      lazy-fetched upstream, S3 blobs) — bespoke glue per source.
    * Token hygiene — `http.extraHeader` lives in `.git/config` on
      disk. In the VFS version the bearer stays in process memory.

  Tagged `:integration_network` and `:cloudflare`. Self-skips when the
  CF management env vars (`CF_API_TOKEN`, `CF_ACCOUNT_ID`) are missing.
  """
  use ExUnit.Case, async: false

  alias Exgit.CloudflareArtifacts
  alias Exgit.CloudflareArtifacts.{Repo, Token}

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

      repo_name = "vfs-baseline-#{System.system_time(:millisecond)}-#{rand_suffix()}"

      on_exit(fn ->
        _ = CloudflareArtifacts.delete_repo(client, repo_name)
      end)

      {:ok, skip: false, client: client, repo_name: repo_name}
    end
  end

  test "baseline lifecycle: provision → seed → boot → commit → pause → rehydrate", ctx do
    if Map.get(ctx, :skip) do
      assert true, "skipped: CF_API_TOKEN / CF_ACCOUNT_ID not set"
    else
      run_demo(ctx)
    end
  end

  defp run_demo(%{client: client, repo_name: repo_name}) do
    timings = %{}

    # ── Phase 0: provision via management API (HTTP, not git) ──────
    {timings, %Repo{remote: git_url}} =
      timed(timings, :create_repo, fn ->
        {:ok, repo} =
          CloudflareArtifacts.create_repo(client,
            name: repo_name,
            default_branch: "main",
            description: "vfs baseline smoketest"
          )

        repo
      end)

    {timings, %Token{plaintext: token}} =
      timed(timings, :mint_token, fn ->
        {:ok, tok} =
          CloudflareArtifacts.create_token(client, repo: repo_name, scope: :write, ttl: 600)

        tok
      end)

    auth = "Authorization: Bearer #{token}"

    # ── Phase 1: seed initial state via `git` ──────────────────────
    seed = make_session_dir("seed")

    git!(~w(init -b main), cd: seed)
    git!(~w(config user.name vfs-test), cd: seed)
    git!(~w(config user.email test@example.com), cd: seed)

    File.write!(Path.join(seed, "README.md"), "# seed\n")
    File.write!(Path.join(seed, "config.json"), "{\"v\":1}\n")

    git!(~w(add .), cd: seed)
    git!(["commit", "-m", "seed"], cd: seed)

    {timings, _} =
      timed(timings, :push_seed, fn ->
        git!(["-c", "http.extraHeader=#{auth}", "push", git_url, "main"], cd: seed)
      end)

    # ── Phase 2: "agent 1 boots" — fresh clone, work locally ───────
    agent1 = new_session_path("agent1")
    scratch = make_session_dir("scratch")

    {timings, _} =
      timed(timings, :clone_boot, fn ->
        git!(["-c", "http.extraHeader=#{auth}", "clone", git_url, agent1])
      end)

    git!(["config", "http.extraHeader", auth], cd: agent1)
    git!(~w(config user.name vfs-test), cd: agent1)
    git!(~w(config user.email test@example.com), cd: agent1)

    # The agent's "VFS" is the OS filesystem. Reads are direct.
    assert File.read!(Path.join(agent1, "README.md")) == "# seed\n"
    assert File.read!(Path.join(agent1, "config.json")) == "{\"v\":1}\n"

    # Per-turn ephemeral scratch is just another temp dir.
    File.write!(Path.join(scratch, "plan.md"), "modify README, add notes\n")
    assert File.read!(Path.join(scratch, "plan.md")) == "modify README, add notes\n"

    new_readme = "# seed\n\n# touched by agent 1\n"
    notes = "agent 1 was here\n"
    File.write!(Path.join(agent1, "README.md"), new_readme)
    File.write!(Path.join(agent1, "notes.md"), notes)
    assert File.read!(Path.join(agent1, "README.md")) == new_readme
    assert File.read!(Path.join(agent1, "notes.md")) == notes

    git!(~w(add .), cd: agent1)
    git!(["commit", "-m", "agent 1 turn"], cd: agent1)

    {timings, _} =
      timed(timings, :push_modified, fn ->
        git!(~w(push origin main), cd: agent1)
      end)

    # ── Phase 3: "pause" — wipe ALL agent-1 state ──────────────────
    File.rm_rf!(agent1)
    File.rm_rf!(scratch)

    # ── Phase 4: "rehydrate" — fresh clone in a new dir ────────────
    agent2 = new_session_path("agent2")

    {timings, _} =
      timed(timings, :clone_rehydrate, fn ->
        git!(["-c", "http.extraHeader=#{auth}", "clone", git_url, agent2])
      end)

    assert File.read!(Path.join(agent2, "README.md")) == new_readme
    assert File.read!(Path.join(agent2, "notes.md")) == notes
    assert File.read!(Path.join(agent2, "config.json")) == "{\"v\":1}\n"

    files = agent2 |> File.ls!() |> Enum.reject(&(&1 == ".git")) |> Enum.sort()
    assert files == ["README.md", "config.json", "notes.md"]

    refute File.exists?(Path.join(scratch, "plan.md"))

    # ── Phase 5: cleanup (also covered by on_exit; timed here) ─────
    {timings, _} =
      timed(timings, :delete_repo, fn ->
        {:ok, _} = CloudflareArtifacts.delete_repo(client, repo_name)
      end)

    File.rm_rf!(seed)
    File.rm_rf!(agent2)

    print_timings(timings, repo_name)
  end

  # ── git driver ─────────────────────────────────────────────────────

  defp git!(args, opts \\ []) do
    opts = Keyword.put_new(opts, :stderr_to_stdout, true)
    {out, status} = System.cmd("git", args, opts)

    if status != 0 do
      raise "git #{Enum.join(args, " ")} failed (exit #{status}):\n#{out}"
    end

    out
  end

  # ── temp dirs ──────────────────────────────────────────────────────

  defp make_session_dir(label) do
    path = new_session_path(label)
    File.mkdir_p!(path)
    path
  end

  defp new_session_path(label) do
    Path.join([
      System.tmp_dir!(),
      "vfs-baseline-#{label}-#{System.system_time(:millisecond)}-#{rand_suffix()}"
    ])
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
      variant: "baseline",
      ts: DateTime.utc_now() |> DateTime.to_iso8601(),
      repo: repo_name,
      total_ms: round_ms(total),
      ops: Map.new(@timing_order, fn op -> {op, round_ms(Map.fetch!(timings, op))} end)
    }
  end

  defp print_human(%{repo: repo_name, total_ms: total, ops: ops}) do
    IO.puts("\n  CF artifacts BASELINE lifecycle for #{repo_name}:")

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

  # ── misc ───────────────────────────────────────────────────────────

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp rand_suffix, do: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
end
