defmodule VFS.ContractsTest do
  @moduledoc """
  Property tests that prove the **published contract** of `:vfs` — what
  consumers can rely on, written as assertions over arbitrary inputs.

  These tests differ from the rest of the suite in shape:

    * They check the contract documented in `@doc` / `@spec` strings,
      not the behavior of the code as written.
    * They generate inputs adversarially, not in the shape we'd
      typically construct.
    * They fail loudly when an invariant is violated, regardless of
      whether the broken behavior is "documented as a limitation."

  The discipline this enforces: when a reviewer finds a contract
  violation, the **first** commit is the property test that fails;
  the **second** commit is the fix that turns it green. That order
  guarantees the fix matches the contract, not just the code we
  thought we wrote.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  # ─────────────────────────────────────────────────────────────────────
  # CONTRACT: walk yields exactly the read-reachable namespace
  # ─────────────────────────────────────────────────────────────────────
  #
  # Stated in `VFS.Mountable.walk/3`'s docstring and implied by every
  # consumer that uses walk for retrieval ("give me every file"). If
  # `read_file(fs, p)` returns `:enoent`, walk must not yield `p`.
  # If walk yields `p`, `read_file(fs, p)` must succeed.
  #
  # Catches Issue 1 (mount-shadowed paths leak through walk) and any
  # future divergence between walk's view and read_file's view of the
  # namespace.
  describe "walk = read-reachable namespace" do
    property "every walk-emitted regular-file path is read_file-reachable" do
      check all spec <- mount_table_spec(), max_runs: 100 do
        fs = build_mount_table(spec)

        walked_files =
          fs
          |> VFS.walk("/")
          |> Stream.filter(fn {_, %VFS.Stat{type: t}} -> t == :regular end)
          |> Enum.map(&elem(&1, 0))

        for path <- walked_files do
          case VFS.read_file(fs, path) do
            {:ok, _, _} ->
              :ok

            other ->
              flunk("""
              walk yielded #{inspect(path)} but read_file returned #{inspect(other)}.
              walk's output and read_file's reachability must agree.
              Mount table:
              #{inspect(spec, pretty: true)}
              """)
          end
        end
      end
    end

    property "no walk emission is hidden from read_file by mount-table shadowing" do
      # Specifically the Issue 1 shape: a root mount with /a/old, plus
      # an /a mount with /new. read_file("/a/old") is :enoent (longest-
      # prefix routes to the /a mount). walk must respect that.
      check all leaf_in_root <- member_of(["/a/x", "/a/y", "/b/z"]),
                inner_in_a <- member_of(["/p", "/q"]),
                max_runs: 30 do
        fs =
          VFS.new()
          |> VFS.mount("/", VFS.Memory.new(%{leaf_in_root => "shadowed"}))
          |> VFS.mount("/a", VFS.Memory.new(%{inner_in_a => "live"}))

        walked = fs |> VFS.walk("/") |> Enum.map(&elem(&1, 0)) |> MapSet.new()

        # Anything walk emits must be readable.
        for path <- walked do
          assert {:ok, _, _} = VFS.read_file(fs, path),
                 "walk emitted #{path} but read_file fails — this is the shadowed-path leak"
        end
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # CONTRACT: walk + Stream.take(N) terminates over unbounded readdir
  # ─────────────────────────────────────────────────────────────────────
  #
  # `readdir/2` returns `Enumerable.t(String.t())`, which the protocol
  # explicitly permits to be unbounded. `walk/3` returns an
  # `Enumerable.t/0` that's lazy. The composition `walk |> Stream.take(N)`
  # therefore must terminate even when readdir returns an infinite stream
  # — the consumer asked for N items, and the work needed to produce N
  # items is bounded.
  #
  # Catches Issue 2 (default walker eagerly Enum.maps the readdir stream).
  describe "walk + Stream.take(N) terminates over unbounded readdir" do
    test "VFS.Test.LazyDir + walk + Stream.take(1) returns within bounded time" do
      fs = VFS.Test.LazyDir.new()

      task =
        Task.async(fn ->
          fs |> VFS.Mountable.walk("/integers", []) |> Enum.take(1)
        end)

      result = Task.yield(task, 1_000) || Task.shutdown(task, :brutal_kill)

      assert match?({:ok, [_]}, result), """
      walk hung when consuming the first item from an unbounded readdir.
      Got: #{inspect(result)}.
      Expected {:ok, [{path, %VFS.Stat{}}]} within 1s.
      """
    end

    test "Stream.take(50) over LazyDir's infinite range terminates promptly" do
      fs = VFS.Test.LazyDir.new()

      task =
        Task.async(fn ->
          fs |> VFS.Mountable.walk("/integers", []) |> Enum.take(50)
        end)

      result = Task.yield(task, 2_000) || Task.shutdown(task, :brutal_kill)

      assert match?({:ok, list} when is_list(list), result), inspect(result)
      {:ok, list} = result
      assert length(list) == 50
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # CONTRACT: VFS.Memory.new/1 produces consistent state, or rejects
  # ─────────────────────────────────────────────────────────────────────
  #
  # The constructor takes a user-provided seed. Whatever it accepts, the
  # resulting backend must satisfy the protocol's invariants — most
  # importantly, every path in the backend must have a single, stable
  # answer to "what type is this?" stat and readdir cannot disagree.
  #
  # Catches Issue 3 (file/descendant collision in seed silently produces
  # contradictory state).
  describe "VFS.Memory.new/1: consistent state or hard rejection" do
    test "seed where one path strictly contains another is rejected" do
      assert_raise ArgumentError, fn ->
        VFS.Memory.new(%{"/a" => "file", "/a/b" => "child"})
      end

      assert_raise ArgumentError, fn ->
        VFS.Memory.new(%{"/a/b/c" => "deep", "/a" => "shallow"})
      end
    end

    test "literal '/' as a file key is rejected" do
      assert_raise ArgumentError, fn ->
        VFS.Memory.new(%{"/" => "anything"})
      end
    end

    property "any accepted seed produces stat/readdir agreement on every path" do
      check all seed <- well_formed_memory_seed(), max_runs: 50 do
        # If the constructor permits the seed, every path in the
        # resulting backend must answer one consistent question:
        # is this a regular file or a directory? stat and readdir
        # must concur.
        mem = VFS.Memory.new(seed)

        for path <- Map.keys(seed) do
          {:ok, %VFS.Stat{type: stat_type}, _} = VFS.Mountable.stat(mem, path)

          case stat_type do
            :regular ->
              # readdir on a regular file must error :enotdir, not list
              # children.
              assert {:error, %VFS.Error{kind: :enotdir}} = VFS.Mountable.readdir(mem, path),
                     "stat says #{path} is :regular but readdir treats it as a directory"

            :directory ->
              # readdir on a directory must succeed.
              assert {:ok, _, _} = VFS.Mountable.readdir(mem, path),
                     "stat says #{path} is :directory but readdir errored"

            other ->
              flunk("unexpected stat type #{inspect(other)} for #{path}")
          end
        end
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # CONTRACT: line_range with last < first or last < 1 is :einval
  # ─────────────────────────────────────────────────────────────────────
  #
  # The `:line_range` option is documented as 1-based inclusive
  # `{first, last}`. Any (first, last) pair where last is an integer
  # less than max(first, 1) is malformed — the contract says it must
  # return `{:error, %VFS.Error{kind: :einval}}`, never an empty or
  # surprising slice.
  #
  # The motivation: agent tools use `:line_range` to retrieve precise
  # context windows from source files. A malformed range must fail
  # loudly so the tool / agent / model can pivot. Silently returning
  # incorrect data is worst-case behavior for an LLM tool boundary.
  #
  # Catches Issue 4 (last < first slips through validation).
  describe "line_range: malformed pairs are :einval" do
    setup do
      mem = VFS.Memory.new(%{"/x" => "line1\nline2\nline3\nline4\nline5\n"})
      {:ok, mem: mem}
    end

    property "any (first, last) with last < max(first, 1) returns :einval", %{mem: mem} do
      check all first <- positive_integer(),
                last <- one_of([integer(-100..0), integer(1..1000)]),
                last < max(first, 1),
                max_runs: 100 do
        result = VFS.Mountable.stream_read(mem, "/x", line_range: {first, last})

        assert match?({:error, %VFS.Error{kind: :einval}}, result), """
        line_range: {#{first}, #{last}} should be :einval but returned:
        #{inspect(result)}
        """
      end
    end

    property "valid ranges (1 <= first <= last <= line_count) succeed", %{mem: mem} do
      check all first <- integer(1..5),
                last <- integer(1..6),
                last >= first,
                max_runs: 30 do
        assert {:ok, stream, _} = VFS.Mountable.stream_read(mem, "/x", line_range: {first, last})
        result = stream |> Enum.to_list() |> IO.iodata_to_binary()
        assert is_binary(result)
      end
    end

    property "valid range with last == :end always succeeds", %{mem: mem} do
      check all first <- integer(1..6), max_runs: 10 do
        assert {:ok, _, _} = VFS.Mountable.stream_read(mem, "/x", line_range: {first, :end})
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # generators
  # ─────────────────────────────────────────────────────────────────────

  defp mount_table_spec do
    list_of(mount_spec(), min_length: 1, max_length: 4)
    |> map(&Enum.uniq_by(&1, fn {mp, _} -> mp end))
  end

  defp mount_spec do
    tuple({
      member_of(["/", "/a", "/b", "/a/sub", "/x/y/z"]),
      file_seed()
    })
  end

  defp file_seed do
    list_of(
      tuple({member_of(["/p", "/q", "/r/s", "/t/u/v"]), binary(min_length: 0, max_length: 8)}),
      min_length: 0,
      max_length: 4
    )
    |> map(&Enum.uniq_by(&1, fn {p, _} -> p end))
    |> map(&Map.new/1)
    # The current Memory.new/1 may accept conflicting seeds; we ensure
    # the seed is well-formed here so this generator is independent of
    # whether Memory's validation has been fixed yet.
    |> map(&drop_conflicts/1)
  end

  defp well_formed_memory_seed do
    list_of(
      tuple({member_of(["/a", "/b/c", "/b/d", "/e/f/g", "/h"]), binary(max_length: 8)}),
      min_length: 1,
      max_length: 5
    )
    |> map(&Enum.uniq_by(&1, fn {p, _} -> p end))
    |> map(&Map.new/1)
    |> map(&drop_conflicts/1)
    |> filter(&(map_size(&1) > 0))
  end

  defp build_mount_table(spec) do
    Enum.reduce(spec, VFS.new(), fn {mp, files}, vfs ->
      VFS.mount(vfs, mp, VFS.Memory.new(files))
    end)
  end

  # Drop any pair of paths where one is a strict path-segment prefix of
  # the other. Used by the seed generators so we test the consistency
  # property on inputs that an honest constructor would accept, not on
  # the ones we know are malformed.
  defp drop_conflicts(map) do
    paths = Map.keys(map)

    bad =
      for a <- paths,
          b <- paths,
          a != b,
          String.starts_with?(b, a <> "/"),
          do: b

    Map.drop(map, bad)
  end
end
