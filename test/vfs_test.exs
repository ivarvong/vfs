defmodule VFSTest do
  @moduledoc """
  Mount-table-specific behavior. Conformance tests for `%VFS{}` as a
  `VFS.Mountable` live in `VFS.MountTableConformanceTest`.
  """
  use ExUnit.Case, async: true

  doctest VFS

  describe "new/1" do
    test "with no args returns an empty mount table" do
      assert %VFS{mounts: []} = VFS.new()
    end

    test "with a map seeds an in-memory root mount" do
      fs = VFS.new(%{"/foo" => "bar"})
      assert {:ok, "bar", _fs} = VFS.read_file(fs, "/foo")
    end

    test "with root: backend mounts the backend at /" do
      mem = VFS.Memory.new(%{"/x" => "y"})
      fs = VFS.new(root: mem)
      assert {:ok, "y", _fs} = VFS.read_file(fs, "/x")
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
  end

  describe "umount/2" do
    test "removes the named mount" do
      fs = VFS.new(%{"/x" => "y"}) |> VFS.umount("/")
      assert %VFS{mounts: []} = fs
    end

    test "no-op for unknown mount" do
      fs = VFS.new(%{"/x" => "y"})
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
  end

  describe "cross-mount mv/3 returns :exdev" do
    test "src and dest in different mounts" do
      fs =
        VFS.new()
        |> VFS.mount("/a", VFS.Memory.new(%{"/x" => "data"}))
        |> VFS.mount("/b", VFS.Memory.new())

      {:ok, fs} = VFS.mkdir(fs, "/b", parents: true)
      assert {:error, :exdev} = VFS.mv(fs, "/a/x", "/b/y")
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
  end

  describe "capabilities/1" do
    test "intersection of all mount capabilities" do
      fs =
        VFS.new()
        |> VFS.mount("/r", VFS.Test.LazyFake.new(%{"/x" => ""}))
        |> VFS.mount("/w", VFS.Memory.new())

      caps = VFS.capabilities(fs)
      # both have :read; only /w has :write — intersection drops :write
      assert MapSet.member?(caps, :read)
      refute MapSet.member?(caps, :write)
    end

    test "empty mount table has empty capabilities" do
      assert VFS.capabilities(VFS.new()) == MapSet.new()
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

  describe "no-mount routing" do
    test "operations on an empty mount table return :enoent" do
      fs = VFS.new()
      assert {:error, :enoent} = VFS.read_file(fs, "/x")
      assert {:error, :enoent} = VFS.write_file(fs, "/x", "")
      assert {:error, :enoent} = VFS.rm(fs, "/x")
    end

    test "exists?/2 on a mount-table fall-through returns synthetic-aware boolean" do
      fs = VFS.new() |> VFS.mount("/git", VFS.Memory.new())
      assert {true, _} = VFS.exists?(fs, "/")
      assert {false, _} = VFS.exists?(fs, "/nope")
    end

    test "stream_read on no-mount path is :enoent" do
      assert {:error, :enoent} = VFS.stream_read(VFS.new(), "/x")
    end
  end

  describe "lstat/2 (delegates to stat)" do
    test "matches stat for a regular file" do
      fs = VFS.new(%{"/a" => "x"})
      {:ok, stat, _} = VFS.Mountable.lstat(fs, "/a")
      assert stat.type == :regular
    end
  end

  describe "readdir with synthetic + backend-error fallback" do
    test "backend returns :enoent but synthetic children exist" do
      fs =
        VFS.new()
        |> VFS.mount("/", VFS.Memory.new())
        |> VFS.mount("/something/deep", VFS.Memory.new())

      {:ok, names, _} = VFS.readdir(fs, "/something")
      assert names == ["deep"]
    end
  end

  describe "readlink, symlink, link via mount table" do
    test "readlink delegates :enotsup from backend" do
      fs = VFS.new(%{"/a" => "x"})
      assert {:error, :enotsup} = VFS.Mountable.readlink(fs, "/a")
    end

    test "readlink on no-mount path is :enoent" do
      assert {:error, :enoent} = VFS.Mountable.readlink(VFS.new(), "/missing")
    end

    test "symlink via mount table delegates :enotsup" do
      fs = VFS.new(%{})
      assert {:error, :enotsup} = VFS.Mountable.symlink(fs, "/target", "/link")
    end

    test "symlink on no-mount path is :enoent" do
      assert {:error, :enoent} = VFS.Mountable.symlink(VFS.new(), "/t", "/l")
    end

    test "link with both endpoints in same mount delegates :enotsup" do
      fs = VFS.new(%{"/a" => "1"})
      assert {:error, :enotsup} = VFS.Mountable.link(fs, "/a", "/b")
    end

    test "link with endpoints in different mounts returns :exdev" do
      fs =
        VFS.new()
        |> VFS.mount("/a", VFS.Memory.new(%{"/x" => ""}))
        |> VFS.mount("/b", VFS.Memory.new())

      assert {:error, :exdev} = VFS.Mountable.link(fs, "/a/x", "/b/y")
    end

    test "link with one endpoint unresolvable returns :enoent" do
      fs = VFS.new()
      assert {:error, :enoent} = VFS.Mountable.link(fs, "/a", "/b")
    end
  end

  describe "materialize across mounts" do
    test "fans out to every mount and threads state back" do
      fs =
        VFS.new()
        |> VFS.mount("/r", VFS.Test.LazyFake.new(%{"/a" => "1"}))
        |> VFS.mount("/m", VFS.Memory.new())

      {:ok, fs2} = VFS.materialize(fs)
      # LazyFake materialize prewarms its cache; subsequent reads should hit.
      {:ok, _, fs3} = VFS.read_file(fs2, "/r/a")

      lazy = fs3.mounts |> Enum.find(fn {p, _} -> p == "/r" end) |> elem(1)
      assert lazy.hits == 1
      assert lazy.misses == 0
    end
  end

  describe "capabilities/1 for a single-mount table" do
    test "intersection over a single mount equals that mount's capabilities" do
      fs = VFS.new() |> VFS.mount("/", VFS.Memory.new())
      caps = VFS.capabilities(fs)
      assert caps == VFS.capabilities(VFS.Memory.new())
    end
  end

  describe "telemetry-wrapped error paths" do
    test "every public helper emits :stop with %{error: reason} on failure" do
      fs = VFS.new()

      assert {:error, :enoent} = VFS.read_file(fs, "/x")
      assert {:error, :enoent} = VFS.stream_read(fs, "/x")
      assert {:error, :enoent} = VFS.write_file(fs, "/x", "")
      assert {:error, :enoent} = VFS.append_file(fs, "/x", "")
      assert {:error, :enoent} = VFS.mkdir(fs, "/x")
      assert {:error, :enoent} = VFS.rm(fs, "/x")
      assert {:error, :enoent} = VFS.chmod(fs, "/x", 0o644)
    end

    test "stream_read success returns the stream and an updated impl" do
      fs = VFS.new(%{"/a" => "hello"})
      {:ok, stream, _fs} = VFS.stream_read(fs, "/a")
      assert stream |> Enum.to_list() |> IO.iodata_to_binary() == "hello"
    end
  end

  describe "cp/3" do
    test "copies a file via read+write" do
      fs = VFS.new(%{"/src" => "data"})
      {:ok, fs} = VFS.cp(fs, "/src", "/dst")
      {:ok, "data", _} = VFS.read_file(fs, "/dst")
      {:ok, "data", _} = VFS.read_file(fs, "/src")
    end

    test "propagates read errors" do
      fs = VFS.new(%{})
      assert {:error, :enoent} = VFS.cp(fs, "/missing", "/dst")
    end
  end

  describe "mv/3" do
    test "moves within the same mount" do
      fs = VFS.new(%{"/src" => "data"})
      {:ok, fs} = VFS.mv(fs, "/src", "/dst")
      {:ok, "data", _} = VFS.read_file(fs, "/dst")
      assert {:error, :enoent} = VFS.read_file(fs, "/src")
    end

    test "no-mount source returns :enoent (not :exdev)" do
      assert {:error, :enoent} = VFS.mv(VFS.new(), "/a", "/b")
    end
  end

  describe "glob pattern relative to non-root" do
    test "resolves match relative to the root argument" do
      fs = VFS.new(%{"/sub/a.ex" => "", "/sub/b.exs" => ""})
      result = fs |> VFS.glob("/sub", "*.ex") |> Enum.sort()
      assert result == ["/sub/a.ex"]
    end
  end

  describe "stat on backend-error other than :enoent" do
    test "readdir error passes through" do
      fs = VFS.new() |> VFS.mount("/", VFS.Test.UnreadableDir.new())
      assert {:error, :eacces} = VFS.readdir(fs, "/borked")
    end

    test "stat error other than :enoent passes through (no synthetic fallback)" do
      fs = VFS.new() |> VFS.mount("/", VFS.Test.UnreadableDir.new())
      assert {:error, :eacces} = VFS.stat(fs, "/locked")
    end
  end

  describe "synthetic dir fallback when backend says :enoent" do
    test "stat falls back to synthetic directory when path is a strict mount prefix" do
      fs =
        VFS.new()
        |> VFS.mount("/", VFS.Memory.new())
        |> VFS.mount("/something/deep", VFS.Memory.new())

      {:ok, stat, _} = VFS.stat(fs, "/something")
      assert stat.type == :directory
    end
  end

  describe "grep over a backend whose stream_read fails" do
    test "skips files that error during stream_read" do
      fs = VFS.new() |> VFS.mount("/", VFS.Test.UnreadableDir.new())
      assert fs |> VFS.grep("/", ~r/anything/) |> Enum.to_list() == []
    end
  end

  describe "symlink/link via mount table — success branches" do
    test "symlink delegates to the backend that supports it" do
      fs = VFS.new() |> VFS.mount("/", VFS.Test.LinksBackend.new())
      {:ok, fs2} = VFS.Mountable.symlink(fs, "/target", "/link")
      [{_, backend}] = fs2.mounts
      assert backend.symlinks == %{"/link" => "/target"}
    end

    test "link delegates to the backend when both endpoints are in the same mount" do
      fs = VFS.new() |> VFS.mount("/", VFS.Test.LinksBackend.new())
      {:ok, fs2} = VFS.Mountable.link(fs, "/old", "/new")
      [{_, backend}] = fs2.mounts
      assert backend.links == %{"/new" => "/old"}
    end
  end

  describe "synthetic stat under a mount that has the path" do
    test "real stat from backend wins over synthetic" do
      fs =
        VFS.new()
        |> VFS.mount("/", VFS.Memory.new(%{"/foo" => "data"}))
        |> VFS.mount("/foo/sub", VFS.Memory.new())

      # /foo exists as a real file in the root mount, even though /foo/sub
      # is a mount point. The real stat takes precedence.
      {:ok, stat, _} = VFS.stat(fs, "/foo")
      assert stat.type == :regular
    end
  end

  describe "materialize halt-on-error" do
    test "returns first error when a mount fails to materialize" do
      fs =
        VFS.new()
        |> VFS.mount("/r", VFS.Test.MaterializeFails.new())
        |> VFS.mount("/m", VFS.Memory.new())

      assert {:error, :eio} = VFS.materialize(fs)
    end
  end
end

defmodule VFS.MountTableConformanceTest do
  @moduledoc false
  # Run the full conformance suite against `%VFS{}` itself (mount table
  # backed by a single root memory mount).
  use VFS.ConformanceCase,
    backend: fn -> VFS.new() |> VFS.mount("/", VFS.Memory.new()) end,
    capabilities: [:read, :write, :chmod, :append]
end
