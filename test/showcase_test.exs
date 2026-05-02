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
    * `examples/list_skills.exs`— real-network codesearch demo: clone
                                  anthropics/skills, parse YAML front-
                                  matter from every SKILL.md, return
                                  structured records. The canonical
                                  example of what this stack enables.
    * `examples/grep.exs`       — real-network regex grep (the simpler
                                  unstructured variant)
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

  describe "9. Real-world: structured codesearch over a public GitHub repo" do
    @moduletag :integration_network
    @moduletag timeout: 60_000

    @doc """
    The agent-loop scenario the library was designed for: answer the
    question "what are all the skills in this repo?" with structured
    data, not lines of regex matches. The same code that runs a
    `Stream.map` against in-memory data runs against a freshly-cloned
    GitHub repo via the same protocol.

    What "codesearch" means here: a *query* over the codebase that
    returns data, not bytes. The output is a list of `{name,
    description, path}` records that an agent can route on, filter,
    sort, or display. That's the value over a regex grep — agents
    consume structure, not text.

    Stack: HTTPS → pure-Elixir git smart-protocol → vfs mount table →
    walk → read_file → YAML front-matter parser. Pure values from end
    to end; no shared mutable state, no shelling out, no `git` binary.
    """
    test "list every skill in anthropics/skills with name + description" do
      # 1. Clone over the network (shallow: HEAD only, no history).
      {:ok, repo} =
        Exgit.clone("https://github.com/anthropics/skills.git", depth: 1)

      # 2. Mount the cloned repo. The wrapper struct + defimpl is in
      #    test/support/exgit_mount.ex; in production it lives in
      #    :exgit itself.
      fs = VFS.new() |> VFS.mount("/repo", ExgitMount.new(repo))

      # 3. The query: walk → filter to SKILL.md → parse front-matter.
      #    Lazy throughout; only the SKILL.md files are actually read.
      skills =
        fs
        |> VFS.walk("/repo")
        |> Stream.map(&elem(&1, 0))
        |> Stream.filter(&String.ends_with?(&1, "/SKILL.md"))
        |> Enum.flat_map(&parse_skill(fs, &1))

      # 4. Verify the structure. The exact set of skills changes over
      #    time; the schema doesn't.
      assert length(skills) >= 10
      assert Enum.all?(skills, &is_binary(&1.name))
      assert Enum.all?(skills, &is_binary(&1.description))
      assert Enum.all?(skills, &String.ends_with?(&1.path, "/SKILL.md"))

      # 5. Specific skills we expect to find as long as anthropics/skills
      #    is what it says on the tin.
      names = Enum.map(skills, & &1.name) |> MapSet.new()
      assert MapSet.member?(names, "pdf"), "expected the pdf skill"
      assert MapSet.member?(names, "skill-creator"), "expected the skill-creator skill"

      # See `examples/list_skills.exs` for the full version with nice
      # output formatting — the same query, just printed instead of
      # asserted.
    end
  end

  # ── helpers used in section 9 ──────────────────────────────────────────

  # Minimal YAML front-matter parser — top-level `key: value` pairs only.
  # SKILL.md uses this shape; pulling in a YAML lib would be overkill.
  defp parse_skill(fs, path) do
    {:ok, content, _fs} = VFS.read_file(fs, path)

    case parse_frontmatter(content) do
      %{"name" => name, "description" => description} ->
        [%{name: name, description: description, path: path}]

      _ ->
        []
    end
  end

  defp parse_frontmatter(content) do
    case String.split(content, "\n") do
      ["---" | rest] ->
        {yaml, _} = Enum.split_while(rest, &(&1 != "---"))

        yaml
        |> Enum.flat_map(fn line ->
          case Regex.run(~r/^([a-zA-Z_][\w-]*):\s+(.+)$/, line) do
            [_, k, v] -> [{k, String.trim(v)}]
            _ -> []
          end
        end)
        |> Map.new()

      _ ->
        %{}
    end
  end
end
