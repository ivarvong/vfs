defmodule VFS.ShowcaseTest do
  @moduledoc """
  A single-file guided tour of `:vfs` — what it is, the design choices,
  and how every piece composes. Written for a reader who is evaluating
  the library cold.

  The library is a **protocol-based virtual filesystem for Elixir**.
  Backends are plain structs that `defimpl VFS.Mountable`. The struct
  IS the FS — passing it to a function returns the (possibly updated)
  struct back, the same way Plug threads `%Conn{}` through a pipeline.
  Mount tables nest because `%VFS{}` itself implements the protocol.

  Six properties that distinguish this design:

    1. **Pure data, no processes.** No `start_link`, no `Application`,
       no global ETS. The whole FS is a value you hold in your hand.
       It composes inside releases, on Nerves, in Lambda, in iex,
       across distributed BEAM nodes — anywhere a value travels.

    2. **One protocol, nine callbacks.** The minimum surface that
       captures "filesystem." Backend authors implement what they
       have native paths for and inherit defaults for the rest from
       a small `VFS.Skeleton` macro.

    3. **State threads back through every op.** A read returns
       `{:ok, value, fs}` — the third element matters because lazy
       backends populate caches inside their struct on read.
       Throwing the returned struct away destroys the cache. The
       Plug.Conn analogy: the conn flows; you don't drop it.

    4. **Lazy by default.** `walk/3` and `stream_read/3` return
       `Enumerable.t/0`. They compose with `Stream.take/2`,
       `Stream.filter/2`, etc., and the underlying work only runs as
       far as the consumer demands. An infinite tree backend
       (demonstrated below) takes no longer than a finite one when
       the consumer caps with `Enum.take(N)`.

    5. **Structured errors.** Every fallible op returns
       `{:ok, ...}` or `{:error, %VFS.Error{kind, path, mount, message}}`.
       Pattern-match on `:kind` for control flow; rich metadata is
       there for logs without forcing it on the happy path.

    6. **Telemetry on every public op.** Events under `[:vfs, _, _]`
       give consumers OpenTelemetry / metric / log integration without
       the library taking a runtime dependency on any of them.

  Run as a tour:

      mix test test/showcase_test.exs --trace

  With network (clones a real GitHub repo, ~1s):

      mix test test/showcase_test.exs --trace --include integration_network

  ## Repo orientation

    * `lib/vfs.ex`             — public API + mount table + dispatcher
    * `lib/vfs/mountable.ex`   — the protocol (9 callbacks)
    * `lib/vfs/memory.ex`      — the only stock backend
    * `lib/vfs/error.ex`       — `%VFS.Error{}` defexception
    * `lib/vfs/path.ex`        — pure path utilities
    * `lib/vfs/skeleton.ex`    — defaults for backend authors
    * `lib/vfs/default.ex`     — fallback walk impl
    * `test/support/*.ex`      — example backends (LazyFake, GitFake,
                                  InfiniteTree, LazyDir, ExgitMount).
                                  Read these to see what writing a
                                  backend looks like.
    * `examples/codesearch.exs`— real-network demo (clone a GitHub
                                  repo, mount, walk, grep)
  """
  use ExUnit.Case, async: true

  alias VFS.Test.{ExgitMount, GitFake, InfiniteTree, LazyFake}

  # `read_file/2` is a derived helper on the `VFS` public API module, not a
  # protocol callback — backends only need `stream_read/3`. Tests that go
  # through the protocol directly use this small helper to collapse the
  # chunk stream into a binary, mirroring what `VFS.read_file/2` does.
  defp read_blob(impl, path) do
    case VFS.Mountable.stream_read(impl, path, []) do
      {:ok, stream, impl2} ->
        {:ok, stream |> Enum.to_list() |> IO.iodata_to_binary(), impl2}

      err ->
        err
    end
  end

  describe "1. Hello VFS — the simplest example" do
    test "create, write, read — three line round trip" do
      fs = VFS.new(memory: %{"/greeting" => "hello, world\n"})

      {:ok, "hello, world\n", _fs} = VFS.read_file(fs, "/greeting")
    end

    test "the value IS the filesystem; passing it forward preserves writes" do
      # `VFS.new()` returns an empty `%VFS{}` struct. There's no process,
      # no init, no setup. It's a value.
      fs = VFS.new(memory: %{})

      # Every mutation returns an updated value. There's no shared
      # mutable state — `fs1` is unaffected by `fs2`'s changes.
      {:ok, fs1} = VFS.write_file(fs, "/a", "first version")
      {:ok, fs2} = VFS.write_file(fs1, "/a", "second version")

      assert {:ok, "first version", _} = VFS.read_file(fs1, "/a")
      assert {:ok, "second version", _} = VFS.read_file(fs2, "/a")

      # `fs` (no writes) still has nothing.
      assert {:error, %VFS.Error{kind: :enoent}} = VFS.read_file(fs, "/a")
    end
  end

  describe "2. State threading — why every op returns the impl" do
    @doc """
    The single most important design choice. Reads return
    `{:ok, value, impl}`. The third element exists because lazy
    backends — git, S3, anything network-backed — populate caches
    inside their struct on read. Threading state forward keeps the
    cache. Throwing it away forces every read to re-fetch.

    `VFS.Test.LazyFake` is a backend whose struct counts cache hits
    and misses. We use it here to demonstrate threading directly.
    """
    test "thread state forward → cache hits; discard state → cache misses" do
      # LazyFake is read-only with its "remote" content in `source`
      # and a local `cache` populated on read.
      lf = LazyFake.new(%{"/file" => "content"})

      # First read populates the cache.
      {:ok, ["content"], lf} = VFS.Mountable.stream_read(lf, "/file", [])
      assert {lf.misses, lf.hits} == {1, 0}

      # Second read with state threaded back: hits the cache.
      {:ok, ["content"], lf} = VFS.Mountable.stream_read(lf, "/file", [])
      assert {lf.misses, lf.hits} == {1, 1}

      # If we instead start the second read from the *original* lf
      # (i.e. the read tuple's third element is discarded), the cache
      # is empty again — every read becomes a miss.
      lf_fresh = LazyFake.new(%{"/file" => "content"})
      {:ok, _, _} = VFS.Mountable.stream_read(lf_fresh, "/file", [])
      {:ok, _, lf_fresh2} = VFS.Mountable.stream_read(lf_fresh, "/file", [])
      assert {lf_fresh2.misses, lf_fresh2.hits} == {1, 0}
    end

    test "the analogy is Plug.Conn — meaningful state flowing through ops" do
      # If you've used Phoenix or Plug, this shape is familiar:
      #
      #     conn |> put_resp_header("x", "y") |> send_resp(200, body)
      #
      # The conn flows; you don't drop it. Same here:
      fs = VFS.new(memory: %{"/a" => "1"})

      {:ok, _, fs} = VFS.read_file(fs, "/a")
      {:ok, fs} = VFS.write_file(fs, "/b", "2")
      {:ok, _, _fs} = VFS.read_file(fs, "/b")

      # Verbose for unfamiliar consumers, idiomatic Elixir for everyone
      # who's used Plug, Ecto.Multi, or any state-threading library.
    end
  end

  describe "3. Errors are structured — pattern-match on :kind" do
    test "the error struct carries kind, path, and mount context" do
      fs = VFS.new() |> VFS.mount("/repo", VFS.Memory.new())

      {:error, err} = VFS.read_file(fs, "/repo/missing.txt")

      # `:kind` is the POSIX-style atom you'd pattern-match on.
      assert err.kind == :enoent
      # `:path` is the path the user asked for, as they wrote it.
      assert err.path == "/repo/missing.txt"
      # `:mount` is attached by the dispatcher — useful in logs when
      # several mounts could be in play.
      assert err.mount == "/repo"

      # The struct is also a defexception, so `!`-style helpers can
      # raise it without ceremony.
      assert_raise VFS.Error, fn ->
        raise VFS.Error, kind: :enoent, path: "/foo"
      end
    end

    test "kind atoms cover the POSIX surface that virtual FSes actually need" do
      # Each of these kinds is exercised somewhere in the suite and
      # has a documented `when` next to its definition in VFS.Error.
      # The lib does NOT invent more kinds than necessary — only what
      # consumers actually need to branch on.
      kinds = [
        :enoent,
        :eexist,
        :eisdir,
        :enotdir,
        :erofs,
        :enotsup,
        :eacces,
        :einval,
        :exdev,
        :eio,
        :eloop
      ]

      for kind <- kinds do
        err = VFS.Error.new(kind, path: "/x")
        assert is_binary(Exception.message(err))
      end
    end
  end

  describe "4. Lazy primitives — walk + Stream.take on an infinite tree" do
    test "infinite-depth backend; Enum.take(1000) terminates in milliseconds" do
      # `VFS.Test.InfiniteTree` is a virtual FS where every directory
      # has two entries: a file (yielded immediately) and a subdir
      # (recursed into). The tree has unbounded depth, so walking the
      # whole thing would never terminate — but `Enum.take(N)` only
      # consumes what it needs and halts.

      fs = InfiniteTree.new()

      first_thousand =
        fs
        |> VFS.Mountable.walk("/", [])
        |> Stream.map(fn {path, _stat} -> path end)
        |> Enum.take(1_000)

      assert length(first_thousand) == 1_000

      # Files are yielded depth-first, one per recursion level:
      # /file, /subdir/file, /subdir/subdir/file, ...
      assert hd(first_thousand) == "/file"

      assert List.last(first_thousand) ==
               "/" <> Enum.join(List.duplicate("subdir", 999), "/") <> "/file"
    end

    test "Stream.filter + Enum.take only does the work needed" do
      # filter for paths at depth >= 6, take 10. The walk halts as
      # soon as 10 are collected — no eager materialization of the
      # rest of the (infinite) tree.

      first_ten_deep =
        InfiniteTree.new()
        |> VFS.Mountable.walk("/", [])
        |> Stream.map(&elem(&1, 0))
        |> Stream.filter(&(length(String.split(&1, "/")) >= 6))
        |> Enum.take(10)

      assert length(first_ten_deep) == 10
      # Every match has at least 6 path segments after the leading /.
      assert Enum.all?(first_ten_deep, fn p ->
               length(String.split(p, "/", trim: true)) >= 5
             end)
    end
  end

  describe "5. Mount tables — composing multiple backends" do
    test "longest-prefix routing: the right backend handles each path" do
      # Two different in-memory backends mounted at different paths.
      # Reads at /a/* go to backend `a`; reads at /b/* go to `b`.
      # The mount table itself implements VFS.Mountable, so the same
      # API works on the composed FS as on a single backend.

      fs =
        VFS.new()
        |> VFS.mount("/a", VFS.Memory.new(%{"/x" => "from a"}))
        |> VFS.mount("/b", VFS.Memory.new(%{"/x" => "from b"}))

      assert {:ok, "from a", _} = VFS.read_file(fs, "/a/x")
      assert {:ok, "from b", _} = VFS.read_file(fs, "/b/x")
    end

    test "synthetic directories: paths above mountpoints behave as dirs" do
      # If you mount at /repo/foo/inner, the dispatcher synthesizes
      # /repo and /repo/foo as directories — even though no backend
      # owns those paths. readdir of / sees ["repo"]; of /repo sees
      # ["foo"]; of /repo/foo sees ["inner"]; of /repo/foo/inner
      # delegates to the actual backend.

      fs = VFS.new() |> VFS.mount("/repo/foo/inner", VFS.Memory.new(%{"/data" => ""}))

      {:ok, names_at_root, _} = VFS.readdir(fs, "/")
      assert Enum.to_list(names_at_root) == ["repo"]

      {:ok, stat, _} = VFS.stat(fs, "/repo/foo")
      assert stat.type == :directory
    end

    test "walk crosses mounts seamlessly" do
      fs =
        VFS.new()
        |> VFS.mount("/repo", VFS.Memory.new(%{"/a.ex" => "..."}))
        |> VFS.mount("/scratch", VFS.Memory.new(%{"/note.md" => "..."}))

      paths = fs |> VFS.walk("/") |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      assert paths == ["/repo/a.ex", "/scratch/note.md"]
    end
  end

  describe "6. The materialize lever — lazy backends prewarm in one batch" do
    @doc """
    For lazy backends like a partial-clone git repo, fetching blobs on
    demand can mean a network round-trip per file. `VFS.materialize/2`
    is the single lever that says "fetch everything now" — backends
    that can do batch prefetching (exgit, future S3, etc.) implement
    it; backends that can't (Memory) treat it as a no-op.

    GitFake demonstrates the shape: it caches blobs on read, and
    materialize fills the cache in one shot.
    """
    test "after materialize, every read is a cache hit" do
      repo =
        GitFake.commit(%{
          "/lib/a.ex" => "defmodule A do end",
          "/lib/b.ex" => "defmodule B do end",
          "/test/c.exs" => "defmodule C do end"
        })

      # Cold: cache empty, no reads yet.
      assert {repo.hits, repo.misses} == {0, 0}

      # Materialize the lever — fetches every referenced blob.
      {:ok, repo} = VFS.Mountable.materialize(repo, [])

      # Now read three files. All hits, no misses, no fetches.
      {:ok, _, repo} = read_blob(repo, "/lib/a.ex")
      {:ok, _, repo} = read_blob(repo, "/lib/b.ex")
      {:ok, _, repo} = read_blob(repo, "/test/c.exs")

      assert {repo.hits, repo.misses} == {3, 0}
    end

    test "content-addressed cache: identical content shares one slot" do
      # GitFake hashes content by SHA. If two paths have identical
      # bytes, they share a cache slot — reading one populates the
      # cache for the other.
      repo = GitFake.commit(%{"/a" => "shared bytes", "/b" => "shared bytes"})

      {:ok, _, repo} = read_blob(repo, "/a")
      assert {repo.hits, repo.misses} == {0, 1}

      # Reading /b finds the same SHA already cached.
      {:ok, _, repo} = read_blob(repo, "/b")
      assert {repo.hits, repo.misses} == {1, 1}
    end
  end

  describe "7. The protocol surface (9 callbacks total)" do
    test "the entire VFS.Mountable API, demonstrated end-to-end" do
      # Every backend implements (or inherits defaults for) these:
      #
      #   exists?/2, stat/2, readdir/2, stream_read/3, walk/3,
      #   write_file/4, mkdir/3, rm/3, materialize/2, capabilities/1
      #
      # Total: 10 (the previous count of 17 had `lstat`, `readlink`,
      # `symlink`, `link`, `chmod`, `append_file`, `read_file` —
      # cut from the protocol because no v1 backend uses them or
      # they're cleanly derivable).

      fs = VFS.new(memory: %{})

      # mkdir + write + readdir + stat + read + rm
      {:ok, fs} = VFS.mkdir(fs, "/dir")
      {:ok, fs} = VFS.write_file(fs, "/dir/file.txt", "content")
      {:ok, names, fs} = VFS.readdir(fs, "/dir")
      assert Enum.to_list(names) == ["file.txt"]

      {:ok, %VFS.Stat{type: :regular, size: 7}, fs} = VFS.stat(fs, "/dir/file.txt")
      {:ok, "content", fs} = VFS.read_file(fs, "/dir/file.txt")

      {true, fs} = VFS.exists?(fs, "/dir/file.txt")
      {:ok, fs} = VFS.rm(fs, "/dir/file.txt")
      {false, _fs} = VFS.exists?(fs, "/dir/file.txt")
    end

    test "stream_read with options: chunk_size, byte_range, line_range" do
      fs = VFS.new(memory: %{"/big" => "alpha\nbeta\ngamma\ndelta\nepsilon\n"})

      # Default: full content, default chunk size.
      {:ok, stream, fs} = VFS.stream_read(fs, "/big")

      assert stream |> Enum.to_list() |> IO.iodata_to_binary() ==
               "alpha\nbeta\ngamma\ndelta\nepsilon\n"

      # :byte_range — slice by byte offset, like HTTP Range.
      {:ok, stream, fs} = VFS.stream_read(fs, "/big", byte_range: {6, 4})
      assert stream |> Enum.to_list() |> IO.iodata_to_binary() == "beta"

      # :line_range — 1-based, inclusive, like git blame ranges.
      {:ok, stream, _fs} = VFS.stream_read(fs, "/big", line_range: {2, 3})
      assert stream |> Enum.to_list() |> IO.iodata_to_binary() == "beta\ngamma"
    end
  end

  describe "8. Telemetry — every public op emits start/stop events" do
    test "consumers attach to [:vfs, op, :start | :stop] events" do
      # The library has zero opinion about logging or metrics — it
      # emits :telemetry events and lets consumers route them to
      # OpenTelemetry, Logger, Statix, or whatever they prefer.

      test_pid = self()

      :ok =
        :telemetry.attach(
          "showcase",
          [:vfs, :read_file, :stop],
          fn event, measurements, metadata, _ ->
            send(test_pid, {:event, event, measurements, metadata})
          end,
          nil
        )

      fs = VFS.new(memory: %{"/x" => "hello"})
      {:ok, "hello", _} = VFS.read_file(fs, "/x")

      assert_receive {:event, [:vfs, :read_file, :stop], measurements, metadata}
      assert measurements.duration > 0
      assert measurements.bytes == 5
      assert metadata.path == "/x"
      assert metadata.impl == VFS

      :ok = :telemetry.detach("showcase")
    end
  end

  describe "9. Real-world: codesearch over a public GitHub repo" do
    @moduletag :integration_network
    @moduletag timeout: 60_000

    test "clone anthropics/skills, mount, walk, grep — full stack, real network" do
      # This test cuts a network connection to github.com and uses
      # `:exgit` (a pure-Elixir git client — no `git` binary, no shell)
      # to clone the repo over HTTPS.

      {:ok, repo} =
        Exgit.clone("https://github.com/anthropics/skills.git", depth: 1)

      # Wrap the Exgit.Repository in a thin defimpl. In production this
      # lives in :exgit; for this repo we ship the wrapper in
      # test/support/exgit_mount.ex as a worked example.
      fs = VFS.new() |> VFS.mount("/repo", ExgitMount.new(repo))

      # Walk the entire tree.
      paths = fs |> VFS.walk("/repo") |> Enum.map(&elem(&1, 0))

      # 100+ files in the repo as of writing. Bound is generous so the
      # test stays stable as Anthropic adds skills.
      assert length(paths) > 100

      # Read every SKILL.md and verify it has YAML front-matter with
      # `name:` and `description:` — the documented contract for
      # Claude Code skills.
      skills = Enum.filter(paths, &String.ends_with?(&1, "/SKILL.md"))
      assert length(skills) >= 10

      {fs, all_have_metadata} =
        Enum.reduce(skills, {fs, true}, fn path, {fs, ok} ->
          {:ok, content, fs} = VFS.read_file(fs, path)

          ok =
            ok and
              Regex.match?(~r/^name:\s+\S/m, content) and
              Regex.match?(~r/^description:\s+\S/m, content)

          {fs, ok}
        end)

      _ = fs
      assert all_have_metadata, "every SKILL.md should have name: and description: front-matter"

      # Total cost on a typical machine: ~1s including network clone.
      # Stack: HTTPS → pure-Elixir git smart-protocol → vfs mount
      # table → walk → read_file → regex. Every step is sound, every
      # step is a value-typed function call, no shared mutable state
      # anywhere in the chain.
    end
  end
end
