defmodule VFS.SkeletonTest do
  @moduledoc """
  Verifies that `use VFS.Skeleton` in a defimpl supplies usable defaults.
  We exercise the defaults through `VFS.Test.LazyFake`, which intentionally
  does *not* override `walk/3`, `materialize/2`, or the
  `:enotsup`-returning ops.
  """
  use ExUnit.Case, async: true

  alias VFS.Test.LazyFake

  test "default read_file derives from stream_read" do
    lf = LazyFake.new(%{"/a" => "hello"})
    assert {:ok, "hello", _} = VFS.Mountable.read_file(lf, "/a")
  end

  test "default walk delegates to VFS.Default and traverses the tree" do
    lf = LazyFake.new(%{"/a" => "1", "/b/c" => "2", "/b/d" => "3"})

    paths = lf |> VFS.Mountable.walk("/", []) |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    assert paths == ["/a", "/b/c", "/b/d"]
  end

  test "unsupported ops return :enotsup by default" do
    lf = LazyFake.new()

    assert {:error, :enotsup} = VFS.Mountable.chmod(lf, "/x", 0o644)
    assert {:error, :enotsup} = VFS.Mountable.symlink(lf, "/target", "/link")
    assert {:error, :enotsup} = VFS.Mountable.link(lf, "/old", "/new")
    assert {:error, :enotsup} = VFS.Mountable.readlink(lf, "/x")
  end

  test "default lstat delegates to stat" do
    lf = LazyFake.new(%{"/a" => "x"})
    {:ok, stat, _} = VFS.Mountable.lstat(lf, "/a")
    assert stat.type == :regular
  end
end
