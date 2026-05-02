defmodule VFS.InfiniteTreeTest do
  @moduledoc """
  Demonstrates that VFS's lazy primitives compose correctly over an
  *infinite* virtual filesystem. The tree has unbounded depth (every
  directory contains a `subdir/` that itself contains a `subdir/`), so
  walking it yields infinitely many files. `Stream.map/2` + `Enum.take/2`
  must terminate without realizing the full tree.
  """
  use ExUnit.Case, async: true

  alias VFS.Test.InfiniteTree

  test "walk + map + take(1000) halts and yields exactly 1000 entries" do
    fs = InfiniteTree.new()

    paths =
      fs
      |> VFS.Mountable.walk("/", [])
      |> Stream.map(fn {path, _stat} -> path end)
      |> Enum.take(1000)

    assert length(paths) == 1000
    assert Enum.all?(paths, &String.ends_with?(&1, "/file"))
    assert hd(paths) == "/file"
    # depth grows 1 per emit on this tree
    assert List.last(paths) == "/" <> Enum.join(List.duplicate("subdir", 999), "/") <> "/file"
  end

  test "works through the mount table too (lazy all the way)" do
    fs = VFS.new() |> VFS.mount("/inf", InfiniteTree.new())

    first_5 =
      fs
      |> VFS.walk("/inf")
      |> Stream.map(&elem(&1, 0))
      |> Enum.take(5)

    assert first_5 == [
             "/inf/file",
             "/inf/subdir/file",
             "/inf/subdir/subdir/file",
             "/inf/subdir/subdir/subdir/file",
             "/inf/subdir/subdir/subdir/subdir/file"
           ]
  end

  test "stream_read over a path the walk produced still works" do
    fs = InfiniteTree.new()

    [{path, _stat} | _] = fs |> VFS.Mountable.walk("/", []) |> Enum.take(1)
    {:ok, stream, _fs} = VFS.Mountable.stream_read(fs, path, [])
    assert stream |> Enum.to_list() |> IO.iodata_to_binary() == path
  end

  test "Stream.filter + take composes lazily — only consumes what's needed" do
    fs = InfiniteTree.new()

    # take 10 paths with depth >= 5 — requires walking past them but the
    # stream halts as soon as 10 are collected
    matches =
      fs
      |> VFS.Mountable.walk("/", [])
      |> Stream.map(&elem(&1, 0))
      |> Stream.filter(&(length(String.split(&1, "/")) >= 6))
      |> Enum.take(10)

    assert length(matches) == 10
  end
end
