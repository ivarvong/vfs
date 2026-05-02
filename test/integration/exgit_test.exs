defmodule VFS.Integration.ExgitTest do
  @moduledoc """
  Real-world integration test: mount a real `Exgit.Repository` through
  VFS via `VFS.Test.ExgitMount`. Verifies that `VFS.Mountable` actually
  fits a non-trivial backend (lazy partial-clone, content-addressed,
  network-capable).

  The repo fixture is built **entirely in pure Elixir** via exgit's own
  `ObjectStore` / `RefStore` / `Object.{Blob,Tree,Commit}` primitives —
  no shelling out to a `git` binary. This matters because: (a) vfs is a
  pure library and we hold the line in tests too; (b) the whole point
  of `:exgit` is to avoid the binary; testing it by going around it
  defeats the purpose.

  Pattern follows `Exgit.FsTest`'s own setup.
  """
  use ExUnit.Case, async: true

  alias Exgit.{ObjectStore, RefStore}
  alias Exgit.Object.{Blob, Commit, Tree}
  alias VFS.Test.ExgitMount

  @moduletag :integration

  setup_all do
    {:ok, repo: build_fixture()}
  end

  # Pure-Elixir fixture: in-memory ObjectStore + RefStore, blobs, trees,
  # commit, and HEAD pointing at refs/heads/main. No git binary, no FS.
  defp build_fixture do
    store = ObjectStore.Memory.new()

    {readme_sha, store} = put_blob(store, "# Test\n")
    {src_sha, store} = put_blob(store, "code\n")
    {a_sha, store} = put_blob(store, "defmodule A do end\n")
    {b_sha, store} = put_blob(store, "defmodule B do end\n")

    lib_tree = Tree.new([{"100644", "a.ex", a_sha}, {"100644", "b.ex", b_sha}])
    {:ok, lib_sha, store} = ObjectStore.put(store, lib_tree)

    root_tree =
      Tree.new([
        {"100644", "README.md", readme_sha},
        {"40000", "lib", lib_sha},
        {"100644", "src.txt", src_sha}
      ])

    {:ok, root_sha, store} = ObjectStore.put(store, root_tree)

    commit =
      Commit.new(
        tree: root_sha,
        parents: [],
        author: "T <t@t> 1700000000 +0000",
        committer: "T <t@t> 1700000000 +0000",
        message: "initial\n"
      )

    {:ok, commit_sha, store} = ObjectStore.put(store, commit)

    {:ok, ref_store} =
      RefStore.write(RefStore.Memory.new(), "refs/heads/main", commit_sha, [])

    {:ok, ref_store} = RefStore.write(ref_store, "HEAD", {:symbolic, "refs/heads/main"}, [])

    %Exgit.Repository{
      object_store: store,
      ref_store: ref_store,
      config: Exgit.Config.new(),
      path: nil
    }
  end

  defp put_blob(store, content) do
    {:ok, sha, store} = ObjectStore.put(store, Blob.new(content))
    {sha, store}
  end

  test "stat through the mount table", %{repo: repo} do
    fs = VFS.new() |> VFS.mount("/repo", ExgitMount.new(repo))

    {:ok, stat, _fs} = VFS.stat(fs, "/repo/README.md")
    assert stat.type == :regular

    {:ok, stat, _fs} = VFS.stat(fs, "/repo/lib")
    assert stat.type == :directory
  end

  test "read_file fetches blob content", %{repo: repo} do
    fs = VFS.new() |> VFS.mount("/repo", ExgitMount.new(repo))

    {:ok, "# Test\n", _fs} = VFS.read_file(fs, "/repo/README.md")
    {:ok, "defmodule A do end\n", _fs} = VFS.read_file(fs, "/repo/lib/a.ex")
  end

  test "readdir lists directory entries sorted", %{repo: repo} do
    fs = VFS.new() |> VFS.mount("/repo", ExgitMount.new(repo))

    {:ok, names, _fs} = VFS.readdir(fs, "/repo/lib")
    assert Enum.to_list(names) == ["a.ex", "b.ex"]

    {:ok, names, _fs} = VFS.readdir(fs, "/repo")
    sorted = names |> Enum.to_list() |> Enum.sort()
    assert "README.md" in sorted
    assert "src.txt" in sorted
    assert "lib" in sorted
  end

  test "walk yields every blob path", %{repo: repo} do
    fs = VFS.new() |> VFS.mount("/repo", ExgitMount.new(repo))

    paths = fs |> VFS.walk("/repo") |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    assert paths == [
             "/repo/README.md",
             "/repo/lib/a.ex",
             "/repo/lib/b.ex",
             "/repo/src.txt"
           ]
  end

  test "rooted walk only yields entries under the root", %{repo: repo} do
    fs = VFS.new() |> VFS.mount("/repo", ExgitMount.new(repo))

    paths = fs |> VFS.walk("/repo/lib") |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    assert paths == ["/repo/lib/a.ex", "/repo/lib/b.ex"]
  end

  test "non-existent paths return :enoent", %{repo: repo} do
    fs = VFS.new() |> VFS.mount("/repo", ExgitMount.new(repo))

    assert {:error, %VFS.Error{kind: :enoent}} = VFS.read_file(fs, "/repo/nope")
  end

  test "writes are refused with :erofs", %{repo: repo} do
    fs = VFS.new() |> VFS.mount("/repo", ExgitMount.new(repo))

    assert {:error, %VFS.Error{kind: :erofs}} = VFS.write_file(fs, "/repo/x", "y")
  end

  test "capabilities reports :read and :lazy, not :write", %{repo: repo} do
    mount = ExgitMount.new(repo)
    caps = VFS.Mountable.capabilities(mount)
    assert MapSet.member?(caps, :read)
    assert MapSet.member?(caps, :lazy)
    refute MapSet.member?(caps, :write)
  end

  test "materialize returns a primed mount", %{repo: repo} do
    {:ok, %ExgitMount{}} = VFS.Mountable.materialize(ExgitMount.new(repo), [])
  end
end
