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
      # Construct malformed pairs directly: pick first >= 1, then pick
      # last as either negative or strictly less than first. No filter
      # — every generated pair is guaranteed-malformed.
      check all first <- integer(1..20),
                last <- one_of([integer(-50..0), integer(1..20) |> map(&min(&1, first - 1))]),
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
      # Generate well-formed pairs by construction rather than
      # filtering — `last = first + offset` guarantees `last >= first`
      # without throwing away any generated value (which would trigger
      # StreamData.FilterTooNarrowError on tight ranges).
      check all first <- integer(1..5),
                offset <- integer(0..5),
                max_runs: 30 do
        last = first + offset
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
  # CONTRACT: stat / readdir / exists? / read_file all agree on a path
  # ─────────────────────────────────────────────────────────────────────
  #
  # The four observation primitives all answer aspects of "what is at
  # this path?" If `stat` says `:regular`, `readdir` must say
  # `:enotdir` (and `read_file` must succeed); if `stat` says
  # `:directory`, `readdir` must succeed (and `read_file` must error
  # with `:eisdir`); if `stat` says `:enoent`, all of `exists?`,
  # `readdir`, and `read_file` must report path-doesn't-exist too.
  #
  # No backend should leak a contradictory view of the same path
  # across these four operations.
  describe "observation consistency: stat / readdir / exists? / read_file agree" do
    property "any path in a freshly-built backend has a coherent type" do
      check all paths <- well_formed_seed_paths(), max_runs: 50 do
        seed = Map.new(paths, fn p -> {p, "x"} end)
        mem = VFS.Memory.new(seed)

        all_paths = paths ++ ["/", "/missing", "/foo/bar/baz"]

        for p <- all_paths do
          stat = VFS.Mountable.stat(mem, p)
          {exists, _} = VFS.Mountable.exists?(mem, p)
          readdir = VFS.Mountable.readdir(mem, p)
          read = VFS.Mountable.stream_read(mem, p, [])

          case stat do
            {:ok, %VFS.Stat{type: :regular}, _} ->
              assert exists, "stat says regular but exists? false for #{p}"

              assert match?({:error, %VFS.Error{kind: :enotdir}}, readdir),
                     "stat says regular but readdir is #{inspect(readdir)} for #{p}"

              assert match?({:ok, _, _}, read), "stat says regular but read failed for #{p}"

            {:ok, %VFS.Stat{type: :directory}, _} ->
              assert exists, "stat says directory but exists? false for #{p}"

              assert match?({:ok, _, _}, readdir),
                     "stat says directory but readdir is #{inspect(readdir)} for #{p}"

              assert match?({:error, %VFS.Error{kind: :eisdir}}, read),
                     "stat says directory but read is #{inspect(read)} for #{p}"

            {:error, %VFS.Error{kind: :enoent}} ->
              refute exists, "stat says enoent but exists? true for #{p}"

              assert match?({:error, %VFS.Error{kind: :enoent}}, readdir),
                     "stat says enoent but readdir is #{inspect(readdir)} for #{p}"

              assert match?({:error, %VFS.Error{kind: :enoent}}, read),
                     "stat says enoent but read is #{inspect(read)} for #{p}"

            other ->
              flunk("unexpected stat for #{p}: #{inspect(other)}")
          end
        end
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # CONTRACT: write_file / read_file round-trip
  # ─────────────────────────────────────────────────────────────────────
  describe "write/read round-trip" do
    property "for any binary content, write then read returns the same bytes" do
      check all path <- member_of(["/a", "/dir/b", "/x/y/z"]),
                content <- binary(min_length: 0, max_length: 200),
                max_runs: 50 do
        mem = VFS.Memory.new()
        {:ok, mem} = VFS.Mountable.write_file(mem, path, content, [])
        {:ok, stream, _} = VFS.Mountable.stream_read(mem, path, [])
        assert stream |> Enum.to_list() |> IO.iodata_to_binary() == content
      end
    end

    property "post-write, stat reports :regular and the correct size" do
      check all content <- binary(max_length: 100), max_runs: 30 do
        mem = VFS.Memory.new()
        {:ok, mem} = VFS.Mountable.write_file(mem, "/a", content, [])
        {:ok, stat, _} = VFS.Mountable.stat(mem, "/a")
        assert stat.type == :regular
        assert stat.size == byte_size(content)
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # CONTRACT: rm / read agree
  # ─────────────────────────────────────────────────────────────────────
  describe "rm + read agreement" do
    property "after rm of a file, stat / read / exists? all report enoent / false" do
      check all content <- binary(max_length: 50), max_runs: 30 do
        mem = VFS.Memory.new()
        {:ok, mem} = VFS.Mountable.write_file(mem, "/x", content, [])
        {:ok, mem} = VFS.Mountable.rm(mem, "/x", [])

        {exists, _} = VFS.Mountable.exists?(mem, "/x")
        refute exists
        assert match?({:error, %VFS.Error{kind: :enoent}}, VFS.Mountable.stat(mem, "/x"))
        assert match?({:error, %VFS.Error{kind: :enoent}}, VFS.Mountable.stream_read(mem, "/x", []))
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # CONTRACT: materialize is idempotent
  # ─────────────────────────────────────────────────────────────────────
  #
  # `VFS.materialize/2` claims to "pre-warm any internal cache. No-op
  # for non-lazy backends." Two calls must produce equivalent state —
  # neither tighter nor looser than one. Any consumer that calls
  # materialize twice (e.g. in retry logic, or as a defensive measure)
  # gets the same result.
  describe "materialize idempotence" do
    test "two materialize calls produce the same observable state — Memory" do
      mem = VFS.Memory.new(%{"/a" => "x", "/b/c" => "y"})
      {:ok, once} = VFS.Mountable.materialize(mem, [])
      {:ok, twice} = VFS.Mountable.materialize(once, [])
      assert once == twice
    end

    test "two materialize calls produce the same cache — GitFake (lazy backend)" do
      repo = VFS.Test.GitFake.commit(%{"/a" => "1", "/b" => "2"})
      {:ok, primed1} = VFS.Mountable.materialize(repo, [])
      {:ok, primed2} = VFS.Mountable.materialize(primed1, [])
      assert primed1.cache == primed2.cache
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # CONTRACT: byte_range validates malformed pairs
  # ─────────────────────────────────────────────────────────────────────
  #
  # `:byte_range` is `{start, length}`. start must be a non-negative
  # integer; length must be a non-negative integer. Anything else is
  # `:einval` — same loud-failure principle as `:line_range`.
  describe "byte_range: malformed pairs are :einval" do
    setup do
      mem = VFS.Memory.new(%{"/x" => "abcdefgh"})
      {:ok, mem: mem}
    end

    property "negative start always fails :einval", %{mem: mem} do
      check all start <- integer(-1000..-1),
                length <- integer(0..100),
                max_runs: 30 do
        result = VFS.Mountable.stream_read(mem, "/x", byte_range: {start, length})
        assert match?({:error, %VFS.Error{kind: :einval}}, result)
      end
    end

    property "negative length always fails :einval", %{mem: mem} do
      check all start <- integer(0..100),
                length <- integer(-1000..-1),
                max_runs: 30 do
        result = VFS.Mountable.stream_read(mem, "/x", byte_range: {start, length})
        assert match?({:error, %VFS.Error{kind: :einval}}, result)
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # CONTRACT: capabilities reflect actual behavior
  # ─────────────────────────────────────────────────────────────────────
  describe "capabilities/1 — declared capabilities match observed behavior" do
    test "Memory: declares :read+:write; both work" do
      caps = VFS.Mountable.capabilities(VFS.Memory.new())
      assert :read in caps
      assert :write in caps
    end

    test "GitFake: declares :read but not :write; mutations are :erofs" do
      repo = VFS.Test.GitFake.commit(%{"/a" => "x"})
      caps = VFS.Mountable.capabilities(repo)
      assert :read in caps
      refute :write in caps
      assert {:error, %VFS.Error{kind: :erofs}} = VFS.Mountable.write_file(repo, "/x", "y", [])
      assert {:error, %VFS.Error{kind: :erofs}} = VFS.Mountable.mkdir(repo, "/d", [])
      assert {:error, %VFS.Error{kind: :erofs}} = VFS.Mountable.rm(repo, "/a", [])
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # CONTRACT: readdir listings never contain duplicate names
  # ─────────────────────────────────────────────────────────────────────
  #
  # A directory entry appearing twice is a silent wrong answer: a
  # consumer deduping by name hides the bug; one iterating visits a
  # child twice. The dangerous case is sibling mounts sharing a
  # synthetic parent — mounts at /a/b and /a/c both imply an "a" entry
  # under /, and the mount-table dispatcher must emit it once.
  describe "readdir: listings never contain duplicate names" do
    test "sibling mounts under a shared synthetic parent dedupe to one name" do
      fs =
        VFS.new()
        |> VFS.mount("/a/b", VFS.Memory.new())
        |> VFS.mount("/a/c", VFS.Memory.new())

      assert {:ok, names, _} = VFS.readdir(fs, "/")
      assert Enum.to_list(names) == ["a"]
    end

    property "any mount table yields duplicate-free readdir at every level" do
      check all spec <- mount_table_spec(), max_runs: 100 do
        fs = build_mount_table(spec)

        dirs =
          spec
          |> Enum.flat_map(fn {mp, _} -> ancestors_of(mp) end)
          |> Enum.uniq()

        for dir <- ["/" | dirs] do
          case VFS.readdir(fs, dir) do
            {:ok, names, _} ->
              names = Enum.to_list(names)

              assert names == Enum.uniq(names), """
              readdir(#{inspect(dir)}) returned duplicates: #{inspect(names)}
              Mount table: #{inspect(spec, pretty: true)}
              """

            {:error, _} ->
              :ok
          end
        end
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # CONTRACT: mkdir is :eexist on any existing path; parents: true is
  # a success no-op over existing directories (mkdir -p semantics)
  # ─────────────────────────────────────────────────────────────────────
  #
  # The :eexist kind is documented as "path already exists" — that
  # includes implicit directories (an ancestor of an existing file) and
  # root, not just directories recorded by a prior mkdir. With
  # `parents: true`, an existing directory is success, never an error,
  # and repeated calls converge to the same state.
  describe "mkdir: :eexist on existing paths, idempotent with parents: true" do
    test "mkdir of an implicit directory is :eexist" do
      mem = VFS.Memory.new(%{"/a/b" => "x"})
      assert {:error, %VFS.Error{kind: :eexist}} = VFS.Mountable.mkdir(mem, "/a", [])
    end

    test "mkdir of root is :eexist" do
      assert {:error, %VFS.Error{kind: :eexist}} = VFS.Mountable.mkdir(VFS.Memory.new(), "/", [])
    end

    test "mkdir parents: true is a success no-op on any existing directory" do
      mem = VFS.Memory.new(%{"/a/b" => "x"})
      assert {:ok, ^mem} = VFS.Mountable.mkdir(mem, "/a", parents: true)
      assert {:ok, ^mem} = VFS.Mountable.mkdir(mem, "/", parents: true)
    end

    property "mkdir with parents: true is idempotent" do
      check all segs <- list_of(member_of(["a", "b", "c"]), min_length: 1, max_length: 3),
                max_runs: 30 do
        path = "/" <> Enum.join(segs, "/")
        {:ok, once} = VFS.Mountable.mkdir(VFS.Memory.new(), path, parents: true)
        assert {:ok, twice} = VFS.Mountable.mkdir(once, path, parents: true)
        assert twice == once
      end
    end

    property "mkdir without parents on any existing directory is :eexist" do
      check all seed <- well_formed_memory_seed(), max_runs: 50 do
        mem = VFS.Memory.new(seed)

        existing_dirs =
          seed |> Map.keys() |> Enum.flat_map(&ancestors_of/1) |> Enum.uniq()

        for dir <- ["/" | existing_dirs] do
          assert match?(
                   {:error, %VFS.Error{kind: :eexist}},
                   VFS.Mountable.mkdir(mem, dir, [])
                 ),
                 "mkdir of existing directory #{dir} did not return :eexist"
        end
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # CONTRACT: mount-table errors speak the user's namespace
  # ─────────────────────────────────────────────────────────────────────
  #
  # %VFS.Error{} documents :path as "the path that failed, as the *user*
  # expressed it". The human-readable message must agree: an error whose
  # message names a mount-stripped backend-internal path (":enoent at
  # /x" for a failure at "/repo/x") leaks a path that does not exist in
  # the user's namespace into logs and exception output.
  describe "mount-table errors: message reflects the user's path" do
    property "errors bubbled through a non-root mount mention the full user path" do
      check all mp <- member_of(["/repo", "/a/b"]),
                file <- member_of(["/nope", "/missing/deep"]),
                max_runs: 30 do
        fs = VFS.new() |> VFS.mount(mp, VFS.Memory.new())
        user_path = mp <> file

        {:error, err} = VFS.read_file(fs, user_path)
        assert err.path == user_path
        assert Exception.message(err) =~ user_path
      end
    end

    test "readdir / write_file / rm errors also carry the user path in the message" do
      fs = VFS.new() |> VFS.mount("/repo", VFS.Memory.new(%{"/file" => "x"}))

      {:error, err} = VFS.readdir(fs, "/repo/file")
      assert err.kind == :enotdir
      assert Exception.message(err) =~ "/repo/file"

      {:error, err} = VFS.write_file(fs, "/repo/file/child", "x")
      assert err.kind == :enotdir
      assert Exception.message(err) =~ "/repo/file/child"

      {:error, err} = VFS.rm(fs, "/repo/gone")
      assert err.kind == :enoent
      assert Exception.message(err) =~ "/repo/gone"
    end

    test "a backend's custom message survives the path rewrite" do
      err = VFS.Error.new(:eio, path: "/x", message: "disk on fire")
      rewritten = VFS.Error.put_path(err, "/repo/x")
      assert rewritten.path == "/repo/x"
      assert Exception.message(rewritten) == "disk on fire"
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # CONTRACT: adversarial inputs to public API don't crash; either
  # succeed deterministically or fail deterministically with :einval
  # (or ArgumentError for constructors).
  # ─────────────────────────────────────────────────────────────────────
  #
  # The library boundary will see hostile inputs in production: paths
  # from LLM-generated tool calls, content from network responses, opt
  # values from runtime config. Every public surface must respond
  # deterministically — no surprise crashes, no silent wrong answers.
  describe "adversarial inputs: VFS.Path operations never crash" do
    property "normalize on hostile UTF-8 always returns an absolute path or raises" do
      check all rest <- string(:utf8, max_length: 200), max_runs: 200 do
        try do
          result = VFS.Path.normalize("/" <> rest)
          assert is_binary(result)
          assert String.starts_with?(result, "/")
        rescue
          ArgumentError -> :ok
        end
      end
    end

    property "normalize on non-absolute input always raises ArgumentError" do
      check all bad <- one_of([constant(""), string(:printable, max_length: 50)]),
                not String.starts_with?(bad, "/"),
                max_runs: 100 do
        assert_raise ArgumentError, fn -> VFS.Path.normalize(bad) end
      end
    end

    property "join never produces a path with empty segments or raw .. or ." do
      check all base <- normalized_path_gen(),
                rel <- string(:printable, max_length: 30),
                max_runs: 100 do
        try do
          result = VFS.Path.join(base, rel)
          # Result is normalized — no doubled slashes, no . or .. left over.
          refute String.contains?(result, "//")
          segs = result |> String.split("/", trim: true)
          refute Enum.any?(segs, &(&1 in [".", ".."]))
        rescue
          ArgumentError -> :ok
        end
      end
    end
  end

  describe "adversarial inputs: VFS.Memory.new/1 never produces inconsistent state" do
    property "any seed accepted produces stat/readdir agreement on every accepted path" do
      check all paths <- list_of(member_of(["/a", "/b/c", "/d/e/f"]), min_length: 1, max_length: 5),
                contents <- list_of(binary(max_length: 30), length: 5),
                max_runs: 50 do
        seed =
          paths
          |> Enum.uniq()
          |> Enum.zip(contents)
          |> drop_path_pair_conflicts()
          |> Map.new()

        try do
          mem = VFS.Memory.new(seed)

          for path <- Map.keys(seed) do
            {:ok, stat, _} = VFS.Mountable.stat(mem, path)
            assert stat.type == :regular, "seeded file #{path} not reported as :regular"
          end
        rescue
          ArgumentError -> :ok
        end
      end
    end
  end

  describe "adversarial inputs: VFS.Memory.new/1 rejects non-binary seeds" do
    # The constructor's docs promise an internally consistent backend or
    # an ArgumentError at construction. A non-binary value (or key)
    # accepted here would defer the crash to the first stat/read — the
    # worst place for it, deep in a consumer's agent loop.
    property "any seed with a non-binary value raises ArgumentError at construction" do
      check all value <- non_binary_term(), max_runs: 50 do
        assert_raise ArgumentError, fn -> VFS.Memory.new(%{"/a" => value}) end
      end
    end

    property "any seed with a non-binary key raises ArgumentError at construction" do
      check all key <- non_binary_term(), max_runs: 50 do
        assert_raise ArgumentError, fn -> VFS.Memory.new(%{key => "content"}) end
      end
    end
  end

  describe "adversarial inputs: stream_read opts never crash" do
    setup do
      mem = VFS.Memory.new(%{"/x" => "a\nb\nc\nd\n"})
      {:ok, mem: mem}
    end

    property "any combination of byte_range and line_range either succeeds or returns :einval",
             %{mem: mem} do
      check all br <- maybe_byte_range(),
                lr <- maybe_line_range(),
                cs <- maybe_chunk_size(),
                max_runs: 100 do
        opts =
          []
          |> maybe_put(:byte_range, br)
          |> maybe_put(:line_range, lr)
          |> maybe_put(:chunk_size, cs)

        # Either succeeds and returns a stream, or fails cleanly with :einval.
        # Never any other error, never a crash.
        case VFS.Mountable.stream_read(mem, "/x", opts) do
          {:ok, stream, _} ->
            # The stream must be consumable to completion without crashing.
            assert is_binary(stream |> Enum.to_list() |> IO.iodata_to_binary())

          {:error, %VFS.Error{kind: :einval}} ->
            :ok

          other ->
            flunk("unexpected return for opts #{inspect(opts)}: #{inspect(other)}")
        end
      end
    end
  end

  defp maybe_byte_range do
    one_of([
      constant(:none),
      tuple({integer(-50..200), integer(-50..200)}),
      constant({:not_a_tuple})
    ])
  end

  defp maybe_line_range do
    one_of([
      constant(:none),
      tuple({integer(-10..20), integer(-10..20)}),
      tuple({integer(1..10), constant(:end)}),
      constant({:bogus})
    ])
  end

  defp maybe_chunk_size do
    one_of([constant(:none), integer(-100..100), constant(:not_an_integer)])
  end

  defp maybe_put(opts, _key, :none), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp drop_path_pair_conflicts(pairs) do
    paths = Enum.map(pairs, &elem(&1, 0))

    bad =
      for a <- paths,
          b <- paths,
          a != b,
          String.starts_with?(b, a <> "/"),
          do: b

    Enum.reject(pairs, fn {p, _} -> p in bad end)
  end

  defp normalized_path_gen do
    list_of(member_of(["foo", "bar", "baz"]), max_length: 4)
    |> map(fn parts -> "/" <> Enum.join(parts, "/") end)
    |> map(&VFS.Path.normalize/1)
  end

  # ─────────────────────────────────────────────────────────────────────
  # generators
  # ─────────────────────────────────────────────────────────────────────

  defp non_binary_term do
    one_of([
      integer(),
      float(),
      atom(:alphanumeric),
      list_of(integer(), max_length: 3),
      constant(nil),
      constant(~c"charlist"),
      map_of(atom(:alphanumeric), integer(), max_length: 2)
    ])
  end

  defp ancestors_of("/"), do: []

  defp ancestors_of(path) do
    case VFS.Path.dirname(path) do
      "/" -> []
      parent -> [parent | ancestors_of(parent)]
    end
  end

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

  defp well_formed_seed_paths do
    list_of(
      member_of(["/a", "/b/c", "/b/d", "/e/f/g", "/h"]),
      min_length: 1,
      max_length: 4
    )
    |> map(&Enum.uniq/1)
    |> map(&drop_path_conflicts/1)
    |> filter(&(&1 != []))
  end

  defp drop_path_conflicts(paths) do
    bad =
      for a <- paths,
          b <- paths,
          a != b,
          String.starts_with?(b, a <> "/"),
          do: b

    paths -- bad
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
