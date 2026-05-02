defmodule VFS.MemoryTest do
  use VFS.ConformanceCase,
    backend: fn -> VFS.Memory.new() end,
    capabilities: [:read, :write]

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
    test "reports :read and :write" do
      caps = VFS.capabilities(VFS.Memory.new())
      assert MapSet.equal?(caps, MapSet.new([:read, :write]))
    end
  end

  describe "rm of root with :recursive" do
    test "wipes everything to a fresh empty backend" do
      {:ok, fs} = VFS.write_file(VFS.Memory.new(), "/a/b", "x")
      {:ok, fs} = VFS.rm(fs, "/", recursive: true)
      assert fs == %VFS.Memory{}
    end

    test "rm on root without :recursive returns :eisdir error" do
      assert {:error, %VFS.Error{kind: :eisdir}} = VFS.rm(VFS.Memory.new(), "/")
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
      {:ok, fs} = VFS.mkdir(fs, "/a/b/c", parents: true)
      {:ok, stat, _} = VFS.stat(fs, "/a/b/c")
      assert stat.type == :directory
    end

    test "with implicit dir as intermediate" do
      fs = VFS.Memory.new()
      {:ok, fs} = VFS.write_file(fs, "/d/x", "")
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

  describe "stream_read invalid options" do
    test "negative byte_range start returns :einval error" do
      fs = VFS.Memory.new()
      {:ok, fs} = VFS.write_file(fs, "/x", "abc")
      assert {:error, %VFS.Error{kind: :einval}} = VFS.stream_read(fs, "/x", byte_range: {-1, 5})
    end

    test "chunk_size of 0 returns :einval error" do
      fs = VFS.Memory.new()
      {:ok, fs} = VFS.write_file(fs, "/x", "abc")
      assert {:error, %VFS.Error{kind: :einval}} = VFS.stream_read(fs, "/x", chunk_size: 0)
    end

    test "negative chunk_size returns :einval error" do
      fs = VFS.Memory.new()
      {:ok, fs} = VFS.write_file(fs, "/x", "abc")
      assert {:error, %VFS.Error{kind: :einval}} = VFS.stream_read(fs, "/x", chunk_size: -1)
    end

    test "byte_range start past EOF yields an empty stream" do
      fs = VFS.Memory.new()
      {:ok, fs} = VFS.write_file(fs, "/x", "abc")
      {:ok, stream, _} = VFS.stream_read(fs, "/x", byte_range: {100, 5})
      assert Enum.to_list(stream) == []
    end

    test "line_range with first < 1 returns :einval error" do
      fs = VFS.Memory.new()
      {:ok, fs} = VFS.write_file(fs, "/x", "a\nb\n")

      assert {:error, %VFS.Error{kind: :einval}} =
               VFS.stream_read(fs, "/x", line_range: {0, 1})
    end

    test "line_range with malformed last returns :einval error" do
      fs = VFS.Memory.new()
      {:ok, fs} = VFS.write_file(fs, "/x", "a\nb\n")

      assert {:error, %VFS.Error{kind: :einval}} =
               VFS.stream_read(fs, "/x", line_range: {1, :bogus})
    end
  end

  describe "directory edge cases" do
    test "readdir on a file returns :enotdir error" do
      {:ok, fs} = VFS.write_file(VFS.Memory.new(), "/file", "")
      assert {:error, %VFS.Error{kind: :enotdir}} = VFS.readdir(fs, "/file")
    end

    test "stream_read on a directory returns :eisdir error" do
      {:ok, fs} = VFS.write_file(VFS.Memory.new(), "/d/x", "")
      assert {:error, %VFS.Error{kind: :eisdir}} = VFS.stream_read(fs, "/d")
    end
  end
end
