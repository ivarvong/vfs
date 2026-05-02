defmodule VFS.LazyDirTest do
  @moduledoc """
  Demonstrates that `readdir/2` returning `t:Enumerable.t/0` enables
  backends with unbounded directory listings. The `LazyDir` test backend
  has `/integers/N` for every non-negative integer N — `readdir("/integers")`
  is an infinite stream. `Stream.take/2` bounds it; `Enum.to_list/1` would
  not return.
  """
  use ExUnit.Case, async: true

  alias VFS.Test.LazyDir

  test "readdir on an infinite directory returns a stream" do
    {:ok, stream, _} = VFS.Mountable.readdir(LazyDir.new(), "/integers")

    refute is_list(stream)

    first_5 = stream |> Stream.take(5) |> Enum.to_list()
    assert first_5 == ["0", "1", "2", "3", "4"]
  end

  test "Stream.take(N) on the infinite readdir terminates promptly" do
    task =
      Task.async(fn ->
        {:ok, stream, _} = VFS.Mountable.readdir(LazyDir.new(), "/integers")
        stream |> Stream.take(1_000) |> Enum.to_list()
      end)

    assert {:ok, names} = Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill)
    assert length(names) == 1_000
    assert hd(names) == "0"
    assert List.last(names) == "999"
  end

  test "individual files in the infinite directory are readable" do
    fs = LazyDir.new()
    {:ok, stream, _} = VFS.Mountable.stream_read(fs, "/integers/42", [])
    assert stream |> Enum.to_list() |> IO.iodata_to_binary() == "42"
  end

  test "stat on the parent directory itself is finite" do
    fs = LazyDir.new()
    {:ok, stat, _} = VFS.Mountable.stat(fs, "/integers")
    assert stat.type == :directory
  end

  test "readdir at the root (bounded) returns a list" do
    {:ok, names, _} = VFS.Mountable.readdir(LazyDir.new(), "/")
    assert is_list(names)
    assert names == ["integers"]
  end

  describe "through the mount table" do
    test "Stream.take over a mounted infinite directory still terminates" do
      fs = VFS.new() |> VFS.mount("/inf", LazyDir.new())

      {:ok, stream, _} = VFS.readdir(fs, "/inf/integers")

      first_3 = stream |> Stream.take(3) |> Enum.to_list()
      assert first_3 == ["0", "1", "2"]
    end

    test "synthetic mountpoint names are still injected when backend listing is bounded" do
      fs =
        VFS.new()
        |> VFS.mount("/", LazyDir.new())
        |> VFS.mount("/extra", VFS.Memory.new())

      {:ok, names, _} = VFS.readdir(fs, "/")
      # Both the LazyDir's bounded ["integers"] and the synthetic ["extra"]
      # are merged. Result is a sorted list (bounded path).
      assert names == ["extra", "integers"]
    end
  end
end
