defmodule VFSTest do
  @moduledoc """
  Mount-table-specific behavior. Conformance tests for `%VFS{}` as a
  `VFS.Mountable` live in `VFS.MountTableConformanceTest`.
  """
  use ExUnit.Case, async: true

  alias VFS.Error

  doctest VFS

  describe "new/0" do
    test "returns an empty mount table" do
      assert %VFS{mounts: []} = VFS.new()
    end

    test "the canonical pattern is `VFS.new() |> VFS.mount(...)`" do
      fs = VFS.new() |> VFS.mount("/", VFS.Memory.new(%{"/foo" => "bar"}))
      assert {:ok, "bar", _fs} = VFS.read_file(fs, "/foo")
    end
  end

  describe "mount/3" do
    test "longest-prefix routing dispatches to the right backend" do
      a = VFS.Memory.new(%{"/in_a" => "from_a"})
      b = VFS.Memory.new(%{"/in_b" => "from_b"})

      fs =
        VFS.new()
        |> VFS.mount("/", a)
        |> VFS.mount("/sub", b)

      assert {:ok, "from_a", _} = VFS.read_file(fs, "/in_a")
      assert {:ok, "from_b", _} = VFS.read_file(fs, "/sub/in_b")
    end

    test "remounting the same point replaces the backend" do
      a = VFS.Memory.new(%{"/x" => "from_a"})
      b = VFS.Memory.new(%{"/x" => "from_b"})

      fs = VFS.new() |> VFS.mount("/", a) |> VFS.mount("/", b)

      assert {:ok, "from_b", _} = VFS.read_file(fs, "/x")
    end

    test "mounts are sorted longest-first" do
      fs =
        VFS.new()
        |> VFS.mount("/", VFS.Memory.new())
        |> VFS.mount("/a", VFS.Memory.new())
        |> VFS.mount("/a/b/c", VFS.Memory.new())
        |> VFS.mount("/a/b", VFS.Memory.new())

      assert ["/a/b/c", "/a/b", "/a", "/"] == Enum.map(VFS.mounts(fs), &elem(&1, 0))
    end

    test "rejects structs that do not implement VFS.Mountable" do
      assert_raise ArgumentError, ~r/does not implement the VFS\.Mountable protocol/, fn ->
        VFS.mount(VFS.new(), "/uri", %URI{})
      end
    end
  end

  describe "umount/2" do
    test "removes the named mount" do
      fs = VFS.new() |> VFS.mount("/", VFS.Memory.new(%{"/x" => "y"})) |> VFS.umount("/")
      assert %VFS{mounts: []} = fs
    end

    test "no-op for unknown mount" do
      fs = VFS.new() |> VFS.mount("/", VFS.Memory.new(%{"/x" => "y"}))
      assert VFS.mounts(fs) == VFS.mounts(VFS.umount(fs, "/nope"))
    end
  end

  describe "synthetic mountpoint directories" do
    test "stat of a strict prefix of a mountpoint returns synthetic directory" do
      fs = VFS.new() |> VFS.mount("/a/b/c", VFS.Memory.new())

      {:ok, stat, _fs} = VFS.stat(fs, "/")
      assert stat.type == :directory

      {:ok, stat, _fs} = VFS.stat(fs, "/a")
      assert stat.type == :directory

      {:ok, stat, _fs} = VFS.stat(fs, "/a/b")
      assert stat.type == :directory
    end

    test "readdir of synthetic dir lists mountpoint names" do
      fs = VFS.new() |> VFS.mount("/repo", VFS.Memory.new()) |> VFS.mount("/tmp", VFS.Memory.new())

      {:ok, names, _fs} = VFS.readdir(fs, "/")
      assert Enum.sort(names) == ["repo", "tmp"]
    end

    test "readdir merges real entries with synthetic mountpoint entries" do
      root = VFS.Memory.new(%{"/already_here" => ""})
      fs = VFS.new() |> VFS.mount("/", root) |> VFS.mount("/git", VFS.Memory.new())

      {:ok, names, _fs} = VFS.readdir(fs, "/")
      assert "already_here" in names
      assert "git" in names
    end

    test "stat falls back to synthetic directory when path is a strict mount prefix" do
      fs =
        VFS.new()
        |> VFS.mount("/", VFS.Memory.new())
        |> VFS.mount("/something/deep", VFS.Memory.new())

      {:ok, stat, _} = VFS.stat(fs, "/something")
      assert stat.type == :directory
    end

    test "readdir falls back to synthetic children when backend says :enoent" do
      fs =
        VFS.new()
        |> VFS.mount("/", VFS.Memory.new())
        |> VFS.mount("/foo/deep", VFS.Memory.new())

      {:ok, names, _} = VFS.readdir(fs, "/foo")
      assert names == ["deep"]
    end
  end

  describe "walk across mounts" do
    test "yields entries from every mount" do
      fs =
        VFS.new()
        |> VFS.mount("/a", VFS.Memory.new(%{"/x" => "1"}))
        |> VFS.mount("/b", VFS.Memory.new(%{"/y" => "2"}))

      paths = fs |> VFS.walk("/") |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      assert paths == ["/a/x", "/b/y"]
    end

    test "rooted walk only yields entries under the root" do
      fs =
        VFS.new()
        |> VFS.mount("/a", VFS.Memory.new(%{"/x" => "1"}))
        |> VFS.mount("/b", VFS.Memory.new(%{"/y" => "2"}))

      paths = fs |> VFS.walk("/a") |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      assert paths == ["/a/x"]
    end

    test "walking under a sub-path of a mount descends into that backend" do
      fs =
        VFS.new()
        |> VFS.mount("/", VFS.Memory.new(%{"/sub/a" => "1", "/sub/b" => "2", "/elsewhere" => "x"}))

      paths = fs |> VFS.walk("/sub") |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      assert paths == ["/sub/a", "/sub/b"]
    end
  end

  describe "capabilities/1" do
    test "intersection of all mount capabilities" do
      fs =
        VFS.new()
        |> VFS.mount("/r", VFS.Test.LazyFake.new(%{"/x" => ""}))
        |> VFS.mount("/w", VFS.Memory.new())

      caps = VFS.capabilities(fs)
      assert MapSet.member?(caps, :read)
      refute MapSet.member?(caps, :write)
    end

    test "empty mount table has empty capabilities" do
      assert VFS.capabilities(VFS.new()) == MapSet.new()
    end

    test "single-mount table equals that mount's capabilities" do
      fs = VFS.new() |> VFS.mount("/", VFS.Memory.new())
      assert VFS.capabilities(fs) == VFS.capabilities(VFS.Memory.new())
    end
  end

  describe "no-mount routing" do
    test "operations on an empty mount table return :enoent" do
      fs = VFS.new()
      assert {:error, %Error{kind: :enoent}} = VFS.read_file(fs, "/x")
      assert {:error, %Error{kind: :enoent}} = VFS.write_file(fs, "/x", "")
      assert {:error, %Error{kind: :enoent}} = VFS.rm(fs, "/x")
      assert {:error, %Error{kind: :enoent}} = VFS.stream_read(fs, "/x")
    end

    test "exists?/2 on a mount-table fall-through returns synthetic-aware boolean" do
      fs = VFS.new() |> VFS.mount("/git", VFS.Memory.new())
      assert {true, _} = VFS.exists?(fs, "/")
      assert {false, _} = VFS.exists?(fs, "/nope")
    end
  end

  describe "assert_implemented!/1" do
    test "returns :ok when the value implements VFS.Mountable" do
      assert :ok = VFS.assert_implemented!(VFS.new())
      assert :ok = VFS.assert_implemented!(VFS.Memory.new())
    end

    test "raises ArgumentError with a helpful message otherwise" do
      assert_raise ArgumentError, ~r/does not implement the VFS\.Mountable protocol/, fn ->
        VFS.assert_implemented!(%URI{})
      end
    end

    test "handles non-struct values" do
      assert_raise ArgumentError, ~r/does not implement the VFS\.Mountable protocol/, fn ->
        VFS.assert_implemented!(:not_a_struct)
      end
    end
  end

  describe "error pass-through from leaf backends" do
    test "readdir error other than :enoent passes through" do
      fs = VFS.new() |> VFS.mount("/", VFS.Test.UnreadableDir.new())
      assert {:error, %Error{kind: :eacces}} = VFS.readdir(fs, "/borked")
    end

    test "stat error other than :enoent passes through with mount attached" do
      fs = VFS.new() |> VFS.mount("/", VFS.Test.UnreadableDir.new())
      assert {:error, %Error{kind: :eacces, mount: "/"}} = VFS.stat(fs, "/locked")
    end
  end

  describe "synthetic stat under a mount that has the path" do
    test "real stat from backend wins over synthetic" do
      fs =
        VFS.new()
        |> VFS.mount("/", VFS.Memory.new(%{"/foo" => "data"}))
        |> VFS.mount("/foo/sub", VFS.Memory.new())

      {:ok, stat, _} = VFS.stat(fs, "/foo")
      assert stat.type == :regular
    end
  end

  describe "materialize across mounts" do
    test "fans out to every mount and threads state back" do
      fs =
        VFS.new()
        |> VFS.mount("/r", VFS.Test.LazyFake.new(%{"/a" => "1"}))
        |> VFS.mount("/m", VFS.Memory.new())

      {:ok, fs2} = VFS.materialize(fs)
      {:ok, _, fs3} = VFS.read_file(fs2, "/r/a")

      lazy = fs3.mounts |> Enum.find(fn {p, _} -> p == "/r" end) |> elem(1)
      assert lazy.hits == 1
      assert lazy.misses == 0
    end

    test "halts and propagates the first error with mount attached" do
      fs =
        VFS.new()
        |> VFS.mount("/r", VFS.Test.MaterializeFails.new())
        |> VFS.mount("/m", VFS.Memory.new())

      assert {:error, %Error{kind: :eio, mount: "/r"}} = VFS.materialize(fs)
    end
  end
end

defmodule VFS.MountTableConformanceTest do
  @moduledoc false
  # Run the full conformance suite against `%VFS{}` itself.
  use VFS.ConformanceCase,
    backend: fn -> VFS.new() |> VFS.mount("/", VFS.Memory.new()) end,
    capabilities: [:read, :write, :mkdir]
end
