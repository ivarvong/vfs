defmodule VFS.Integration.ExgitTest do
  @moduledoc """
  Real-world integration test: mount a real `Exgit.Repository` through
  VFS via `VFS.Test.ExgitMount`. Verifies that `VFS.Mountable` actually
  fits a non-trivial backend (lazy partial-clone, content-addressed,
  network-capable).

  Requires the `git` binary on PATH for fixture setup.
  """
  use ExUnit.Case, async: false

  alias VFS.Test.ExgitMount

  @moduletag :integration

  setup_all do
    {tmp, repo} = setup_fixture()
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp, repo: repo}
  end

  defp setup_fixture do
    tmp = Path.join(System.tmp_dir!(), "vfs_exgit_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", tmp])

    File.write!(Path.join(tmp, "README.md"), "# Test\n")
    File.write!(Path.join(tmp, "src.txt"), "code\n")
    File.mkdir_p!(Path.join(tmp, "lib"))
    File.write!(Path.join(tmp, "lib/a.ex"), "defmodule A do end\n")
    File.write!(Path.join(tmp, "lib/b.ex"), "defmodule B do end\n")

    {_, 0} = System.cmd("git", ["-C", tmp, "config", "user.email", "test@test.com"])
    {_, 0} = System.cmd("git", ["-C", tmp, "config", "user.name", "Test"])
    {_, 0} = System.cmd("git", ["-C", tmp, "add", "."])
    {_, 0} = System.cmd("git", ["-C", tmp, "commit", "-q", "-m", "initial"])

    # Exgit.open expects the .git directory itself, not the working tree.
    {:ok, repo} = Exgit.open(Path.join(tmp, ".git"))
    {tmp, repo}
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
