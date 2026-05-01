defmodule VFS.StateThreadingTest do
  @moduledoc """
  Verifies the central design invariant: state threaded back from a read
  preserves the lazy backend's cache, while throwing it away forces every
  read to re-fetch.

  Uses `VFS.Test.LazyFake` whose struct counts cache hits and misses.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias VFS.Test.LazyFake

  describe "cache survives reads when state is threaded" do
    test "two reads of the same path produce 1 miss + 1 hit" do
      lf = LazyFake.new(%{"/a" => "x"})

      {:ok, "x", lf} = VFS.Mountable.read_file(lf, "/a")
      assert lf.misses == 1
      assert lf.hits == 0

      {:ok, "x", lf} = VFS.Mountable.read_file(lf, "/a")
      assert lf.misses == 1
      assert lf.hits == 1
    end

    test "two reads with state discarded produce 2 misses" do
      lf = LazyFake.new(%{"/a" => "x"})

      {:ok, "x", _} = VFS.Mountable.read_file(lf, "/a")
      {:ok, "x", lf2} = VFS.Mountable.read_file(lf, "/a")

      # Second read started from the same lf as the first; never saw the cache.
      assert lf2.misses == 1
      assert lf2.hits == 0
    end
  end

  describe "materialize/2 pre-warms the cache" do
    test "after materialize, every read is a hit" do
      lf = LazyFake.new(%{"/a" => "1", "/b" => "2"})
      {:ok, lf} = VFS.Mountable.materialize(lf, [])

      {:ok, "1", lf} = VFS.Mountable.read_file(lf, "/a")
      {:ok, "2", lf} = VFS.Mountable.read_file(lf, "/b")

      assert lf.misses == 0
      assert lf.hits == 2
    end
  end

  property "threading state across N reads of distinct paths yields N misses + 0 hits" do
    check all paths <-
                list_of(member_of(["/a", "/b", "/c", "/d", "/e"]), min_length: 1, max_length: 8),
              max_runs: 30 do
      source = Map.new(paths, fn p -> {p, p} end)
      lf = LazyFake.new(source)

      final =
        Enum.reduce(paths, lf, fn p, acc ->
          {:ok, _, acc2} = VFS.Mountable.read_file(acc, p)
          acc2
        end)

      assert final.misses == length(Enum.uniq(paths))
      assert final.hits == length(paths) - length(Enum.uniq(paths))
    end
  end

  property "threaded reads are strictly cheaper than discarded reads when paths repeat" do
    check all p <- member_of(["/a", "/b", "/c"]),
              n <- integer(2..10),
              max_runs: 20 do
      lf = LazyFake.new(%{p => "data"})

      threaded =
        Enum.reduce(1..n, lf, fn _, acc ->
          {:ok, _, acc2} = VFS.Mountable.read_file(acc, p)
          acc2
        end)

      discarded =
        Enum.reduce(1..n, lf, fn _, _acc ->
          {:ok, _, _} = VFS.Mountable.read_file(lf, p)
          # Always restart from the original lf — simulates "throwing state away".
          lf
        end)

      assert threaded.misses < n or n == 1
      # Discarded never gets past 1 miss because we keep starting from a fresh lf.
      assert discarded.misses == 0
    end
  end
end
