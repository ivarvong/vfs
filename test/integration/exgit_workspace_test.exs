defmodule VFS.Integration.ExgitWorkspaceTest do
  @moduledoc """
  End-to-end agent-turn demo on top of a real on-disk git repo.

  Validates that **`Exgit.Workspace` + `%VFS{}` mount table** works as
  the state backend for an agent loop:

    * `/repo`    → `Exgit.Workspace` (writable working tree on a git ref)
    * `/scratch` → `VFS.Memory` (ephemeral, per-turn)

  An agent reads source through the unified `%VFS{}`, scribbles
  intermediate notes to scratch, modifies a source file, then steps
  out of the protocol to call git-aware ops (`Workspace.diff/1`,
  `Workspace.commit/2`) on the workspace struct directly. The commit
  lands as a real ref in a real on-disk bare repo at:

      tmp/agent_demo_repo

  After the test runs you can inspect with the git CLI:

      git --git-dir=tmp/agent_demo_repo log --all --oneline
      git --git-dir=tmp/agent_demo_repo show refs/heads/agent-turn-1
      git --git-dir=tmp/agent_demo_repo ls-tree -r refs/heads/agent-turn-1

  The fixture is built entirely in pure Elixir (no shelling out to a
  `git` binary) — same precedent as `exgit_test.exs`.
  """
  use ExUnit.Case, async: false

  alias Exgit.Object.{Blob, Commit, Tree}
  alias Exgit.{ObjectStore, RefStore, Workspace}

  @moduletag :integration

  @repo_path Path.expand("tmp/agent_demo_repo", File.cwd!())

  setup do
    File.rm_rf!(@repo_path)
    {:ok, repo} = Exgit.init(path: @repo_path)
    repo = seed_initial_commit(repo)
    {:ok, repo: repo}
  end

  test "agent turn: read /repo, write /scratch, modify /repo, commit", %{repo: repo} do
    fs =
      VFS.new()
      |> VFS.mount("/repo", Workspace.open(repo, "HEAD"))
      |> VFS.mount("/scratch", VFS.Memory.new())

    {:ok, source, fs} = VFS.read_file(fs, "/repo/lib/a.ex")
    assert source == "defmodule A do end\n"

    {:ok, fs} = VFS.write_file(fs, "/scratch/notes.md", "saw module A\n")
    {:ok, "saw module A\n", fs} = VFS.read_file(fs, "/scratch/notes.md")

    new_source = source <> "\n# touched by agent\n"
    {:ok, fs} = VFS.write_file(fs, "/repo/lib/a.ex", new_source)

    # State threaded back: the next read sees the new content because
    # the mount table updated the workspace's `head_tree` in its slot.
    {:ok, ^new_source, fs} = VFS.read_file(fs, "/repo/lib/a.ex")

    # Other files in the repo are untouched and still readable.
    {:ok, "defmodule B do end\n", fs} = VFS.read_file(fs, "/repo/lib/b.ex")

    # Step out of the protocol for git-aware ops. They live on the
    # workspace struct, not `VFS.Mountable`.
    ws = workspace_from(fs, "/repo")

    {:ok, [{:modified, "lib/a.ex"}], ws} = Workspace.diff(ws)

    {:ok, commit_sha, ws} =
      Workspace.commit(ws,
        message: "agent: touch a.ex",
        author: %{name: "agent", email: "agent@example.com"},
        update_ref: "refs/heads/agent-turn-1"
      )

    assert byte_size(commit_sha) == 20

    # The new ref persisted to the on-disk RefStore.
    assert {:ok, ^commit_sha} =
             RefStore.resolve(ws.repo.ref_store, "refs/heads/agent-turn-1")

    # The workspace is now pristine on its new base_ref — fresh reads
    # against /repo go through `refs/heads/agent-turn-1` and see the
    # committed state.
    assert ws.head_tree == nil
    assert ws.base_ref == "refs/heads/agent-turn-1"

    {:ok, committed, _ws} = Workspace.read(ws, "lib/a.ex")
    assert committed == new_source

    IO.puts("""

    Inspect the demo repo at #{@repo_path}:

        git --git-dir=#{@repo_path} log --all --oneline
        git --git-dir=#{@repo_path} show refs/heads/agent-turn-1
        git --git-dir=#{@repo_path} ls-tree -r refs/heads/agent-turn-1
    """)
  end

  # ── helpers ────────────────────────────────────────────────────────

  defp workspace_from(%VFS{} = fs, mountpoint) do
    {^mountpoint, ws} = List.keyfind(VFS.mounts(fs), mountpoint, 0)
    ws
  end

  # Seeds an initial commit on `refs/heads/main` containing:
  #
  #     README.md
  #     src.txt
  #     lib/a.ex
  #     lib/b.ex
  #
  # All writes go through the disk-backed object/ref stores via the
  # public protocol — no `git` binary, no shelling out.
  defp seed_initial_commit(repo) do
    {repo, readme_sha} = put_blob(repo, "# Demo repo\n")
    {repo, src_sha} = put_blob(repo, "code\n")
    {repo, a_sha} = put_blob(repo, "defmodule A do end\n")
    {repo, b_sha} = put_blob(repo, "defmodule B do end\n")

    lib_tree = Tree.new([{"100644", "a.ex", a_sha}, {"100644", "b.ex", b_sha}])
    {repo, lib_sha} = put_object(repo, lib_tree)

    root_tree =
      Tree.new([
        {"100644", "README.md", readme_sha},
        {"40000", "lib", lib_sha},
        {"100644", "src.txt", src_sha}
      ])

    {repo, root_sha} = put_object(repo, root_tree)

    commit =
      Commit.new(
        tree: root_sha,
        parents: [],
        author: "demo <demo@x> 1700000000 +0000",
        committer: "demo <demo@x> 1700000000 +0000",
        message: "initial\n"
      )

    {repo, commit_sha} = put_object(repo, commit)

    {:ok, ref_store} = RefStore.write(repo.ref_store, "refs/heads/main", commit_sha, [])
    %{repo | ref_store: ref_store}
  end

  defp put_blob(repo, content), do: put_object(repo, Blob.new(content))

  defp put_object(repo, object) do
    {:ok, sha, store} = ObjectStore.put(repo.object_store, object)
    {%{repo | object_store: store}, sha}
  end
end
