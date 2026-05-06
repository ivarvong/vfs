defmodule VFS.Integration.CloudflareArtifactsTest do
  @moduledoc """
  End-to-end agent-loop persistence demo against real Cloudflare Artifacts.

  This is the **rehydration story** — the durable backing for an agent
  loop:

    1. *boot* — push initial state to a fresh branch on a CF artifacts
       repo.
    2. *agent session 1* — clone the branch, mount it via
       `Exgit.Workspace` into a `%VFS{}` next to a `VFS.Memory` scratch.
       Read and write files through the unified `VFS` surface, commit,
       push back to CF, then drop **all** in-memory state.
    3. *rehydrate* — fresh clone of the same branch in a brand-new repo
       value with no shared object cache or process state. Mount it,
       read through VFS, and verify session 1's writes persisted.

  If session 2 sees session 1's edits, the artifact-backed agent loop
  works: durable state lives on Cloudflare; the agent process is
  fungible.

  Tagged `:integration_network` and `:cloudflare`. Self-skips when the
  CF env vars are missing. Cleans up its branch on teardown so repeated
  runs don't pollute `ci.git`.
  """
  use ExUnit.Case, async: false

  alias Exgit.Object.{Blob, Commit, Tree}
  alias Exgit.{ObjectStore, RefStore, Repository, Transport, Workspace}

  @moduletag :integration_network
  @moduletag :cloudflare
  @moduletag timeout: 120_000

  setup_all do
    url = System.get_env("CF_ARTIFACT_REMOTE")
    tok = System.get_env("CF_ARTIFACT_TOKEN")

    if is_nil(url) or url == "" or is_nil(tok) or tok == "" do
      {:ok, skip: true}
    else
      branch = "vfs-rehydrate-#{System.system_time(:millisecond)}-#{rand_suffix()}"
      ref = "refs/heads/" <> branch
      remote_ref = "refs/remotes/origin/" <> branch

      on_exit(fn ->
        repo = empty_repo()
        _ = Exgit.push(repo, transport(url, tok), refspecs: [{:delete, ref}])
      end)

      {:ok, url: url, tok: tok, branch: branch, ref: ref, remote_ref: remote_ref}
    end
  end

  test "boot → commit → pause → rehydrate persists state through CF artifacts", ctx do
    if Map.get(ctx, :skip) do
      assert true, "skipped: CF_ARTIFACT_REMOTE / CF_ARTIFACT_TOKEN not set"
    else
      run_demo(ctx)
    end
  end

  defp run_demo(%{url: url, tok: tok, ref: ref, remote_ref: remote_ref}) do
    # ── Phase 1: seed initial state on CF ───────────────────────────
    {seed_repo, seed_sha} = build_seed_commit()
    {:ok, seed_repo} = put_ref(seed_repo, ref, seed_sha)
    {:ok, _} = Exgit.push(seed_repo, transport(url, tok), refspecs: [ref])

    # ── Phase 2: "agent boots" — fresh clone, mount via VFS ─────────
    # CF artifacts advertises `shallow` but not `filter`, so a partial
    # clone is rejected upstream. Eager clone is fine for the agent
    # loop demo — pack is tiny.
    {:ok, agent1_repo} = Exgit.clone(transport(url, tok))
    assert agent1_repo.mode == :eager

    # Open the workspace on the remote-tracking ref. Exgit.clone rewrites
    # `refs/heads/X` → `refs/remotes/origin/X` for every fetched branch
    # except the server's default HEAD, so this is the canonical local
    # name for "agent 1 just cloned this branch."
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

    # ── Phase 2b: agent mutates the working tree through VFS ────────
    new_readme = "# seed\n\n# touched by agent 1\n"
    notes = "agent 1 was here\n"

    {:ok, fs1} = VFS.write_file(fs1, "/repo/README.md", new_readme)
    {:ok, fs1} = VFS.write_file(fs1, "/repo/notes.md", notes)

    # State threaded back: subsequent reads see the new content.
    {:ok, ^new_readme, fs1} = VFS.read_file(fs1, "/repo/README.md")
    {:ok, ^notes, fs1} = VFS.read_file(fs1, "/repo/notes.md")

    # ── Phase 2c: commit through Workspace, push to CF ──────────────
    # Git-aware ops live on the workspace struct; pull it from its
    # mount slot, commit, then push the underlying repo to CF.
    ws = workspace_from(fs1, "/repo")

    {:ok, [{:modified, "README.md"}, {:added, "notes.md"}], ws} =
      sorted_diff(ws)

    {:ok, _commit_sha, ws} =
      Workspace.commit(ws,
        message: "agent 1 turn",
        author: %{name: "vfs-test", email: "test@example.com"},
        update_ref: ref
      )

    {:ok, _push} = Exgit.push(ws.repo, transport(url, tok), refspecs: [ref])

    # ── Phase 3: "pause" — drop ALL agent-1 state ───────────────────
    fs1 = nil
    ws = nil
    agent1_repo = nil
    _ = {fs1, ws, agent1_repo}

    # ── Phase 4: "rehydrate" — fresh clone, fresh mount, verify ─────
    {:ok, agent2_repo} = Exgit.clone(transport(url, tok))

    # Brand-new object store, brand-new ref store. No shared state.
    refute identical_repos?(agent2_repo, seed_repo)

    fs2 =
      VFS.new()
      |> VFS.mount("/repo", Workspace.open(agent2_repo, remote_ref))
      |> VFS.mount("/scratch", VFS.Memory.new())

    # The modification persisted across the pause.
    {:ok, ^new_readme, fs2} = VFS.read_file(fs2, "/repo/README.md")

    # The new file persisted too.
    {:ok, ^notes, fs2} = VFS.read_file(fs2, "/repo/notes.md")

    # The seed file untouched by agent 1 is still there.
    {:ok, "{\"v\":1}\n", fs2} = VFS.read_file(fs2, "/repo/config.json")

    # readdir sees the full post-agent state without needing a walk
    # (which would require materializing a lazy partial clone).
    {:ok, names, fs2} = VFS.readdir(fs2, "/repo")
    assert Enum.sort(Enum.to_list(names)) == ["README.md", "config.json", "notes.md"]

    # Scratch is fresh — only durable repo state survived the pause.
    assert {:error, %VFS.Error{kind: :enoent}} =
             VFS.read_file(fs2, "/scratch/plan.md")
  end

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

  # Sanity check that the rehydrated repo really is a fresh value, not
  # a stale reference. Different object_store identities prove no
  # cache leaked across the pause.
  defp identical_repos?(%Repository{object_store: a}, %Repository{object_store: b}), do: a == b

  defp rand_suffix,
    do: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
end
