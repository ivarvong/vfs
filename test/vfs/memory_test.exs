defmodule VFS.MemoryTest do
  use VFS.ConformanceCase,
    backend: fn -> VFS.Memory.new() end,
    capabilities: [:read, :write, :chmod, :append]

  doctest VFS.Memory

  describe "VFS.Memory.new/1 (direct construction)" do
    test "without args returns an empty backend" do
      mem = VFS.Memory.new()
      assert mem.tree == %{}
      assert mem.dirs == MapSet.new()
    end

    test "seeds files with normalized paths" do
      mem = VFS.Memory.new(%{"/foo/./bar" => "x"})
      assert Map.fetch!(mem.tree, "/foo/bar") == "x"
    end
  end

  describe "capabilities" do
    test "reports :read, :write, :chmod, :append" do
      caps = VFS.capabilities(VFS.Memory.new())
      assert MapSet.member?(caps, :read)
      assert MapSet.member?(caps, :write)
      assert MapSet.member?(caps, :chmod)
      assert MapSet.member?(caps, :append)
    end
  end

  describe "rm of root with :recursive" do
    test "wipes everything to a fresh empty backend" do
      {:ok, fs} = VFS.write_file(VFS.Memory.new(), "/a/b", "x")
      {:ok, fs} = VFS.rm(fs, "/", recursive: true)
      assert fs == %VFS.Memory{}
    end

    test "rm on root without :recursive returns :eisdir" do
      assert {:error, :eisdir} = VFS.rm(VFS.Memory.new(), "/")
    end
  end

  describe "rm_recursive with explicit dirs" do
    test "removes empty mkdir'd dirs from the dirs MapSet" do
      fs = VFS.Memory.new()
      {:ok, fs} = VFS.mkdir(fs, "/d/sub", parents: true)
      assert MapSet.member?(fs.dirs, "/d/sub")
      assert MapSet.member?(fs.dirs, "/d")

      {:ok, fs} = VFS.rm(fs, "/d", recursive: true)
      refute MapSet.member?(fs.dirs, "/d/sub")
      refute MapSet.member?(fs.dirs, "/d")
    end
  end

  describe "mkdir -p hits already-existing intermediates" do
    test "no-ops on dirs that already exist on the path" do
      fs = VFS.Memory.new()
      {:ok, fs} = VFS.mkdir(fs, "/a")
      # /a already exists; mkdir -p /a/b/c traverses /a as existing intermediate
      {:ok, fs} = VFS.mkdir(fs, "/a/b/c", parents: true)
      {:ok, stat, _} = VFS.stat(fs, "/a/b/c")
      assert stat.type == :directory
    end

    test "with implicit dir as intermediate" do
      fs = VFS.Memory.new()
      # /d implicit via /d/x
      {:ok, fs} = VFS.write_file(fs, "/d/x", "")
      # mkdir -p /d/sub/inner: /d already implicit, /d/sub and /d/sub/inner are new
      {:ok, fs} = VFS.mkdir(fs, "/d/sub/inner", parents: true)
      {:ok, stat, _} = VFS.stat(fs, "/d/sub/inner")
      assert stat.type == :directory
    end
  end

  describe "stream_read empty content" do
    test "yields an empty stream for an empty file" do
      fs = VFS.Memory.new()
      {:ok, fs} = VFS.write_file(fs, "/empty", "")
      {:ok, stream, _} = VFS.stream_read(fs, "/empty")
      assert Enum.to_list(stream) == []
    end
  end

  describe "directory edge cases" do
    test "readdir on a file returns :enotdir" do
      {:ok, fs} = VFS.write_file(VFS.Memory.new(), "/file", "")
      assert {:error, :enotdir} = VFS.readdir(fs, "/file")
    end

    test "stream_read on a directory returns :eisdir" do
      {:ok, fs} = VFS.write_file(VFS.Memory.new(), "/d/x", "")
      assert {:error, :eisdir} = VFS.stream_read(fs, "/d")
    end

    test "chmod on a non-existent path returns :enoent" do
      assert {:error, :enoent} = VFS.chmod(VFS.Memory.new(), "/missing", 0o644)
    end

    test "chmod on a directory works" do
      fs = VFS.Memory.new()
      {:ok, fs} = VFS.mkdir(fs, "/d")
      {:ok, fs} = VFS.chmod(fs, "/d", 0o755)
      {:ok, stat, _} = VFS.stat(fs, "/d")
      assert stat.mode == 0o755
    end
  end
end
