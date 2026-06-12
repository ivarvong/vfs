# `vfs` — protocol-based virtual filesystem for the Elixir AI tools stack

A new library that replaces `feat/mountable-virtual-filesystem-core` in `just_bash` and becomes a shared dep with `pyex`, so an agent can hand the same filesystem state back and forth between bash execution and Python interpretation.

> **Name**: `VFS` — module acronym stays uppercased everywhere, never `Vfs` (matches the `JustBash.FS` convention from `feat/git-fs` commit `6250b8f` "uppercase FS acronym in new module names"). Hex package: `:vfs` — available on hex.pm.
>
> **Repo**: `ivarvong/vfs`.
>
> **Status**: design decisions settled below; staff-reviewed by @daveLucia.
>
> **Amended 2026-06-10** (pre-0.1.0 release): code sketches below were written before implementation and have been updated to match the shipped surface — the 10-callback protocol, `%VFS.Error{}` struct returns (the draft used bare atoms), the trimmed capability set, and no `grep`/`glob`/`cp`/`mv` helpers in the library (consumer-side compositions). The decision table and rationale are original. Where this document and the code disagree, that is a bug — see CLAUDE.md.
>
> | Decision | Choice |
> |---|---|
> | Protocol name | `VFS.Mountable` (renamed from `VFS.Filesystem` per Dave — "filesystem" is overloaded) |
> | Dispatch substrate | Single protocol, not behaviours |
> | Reads thread state back | Yes (every op returns updated impl) |
> | Mount-table-as-backend | `%VFS{}` itself implements the protocol |
> | Primary read API | Lazy: `stream_read/3` (Enumerable). `read_file/2` is a derived helper on `VFS`, not a protocol callback. |
> | Streaming/pushdown | First-class in v1 (`stream_read`, `walk`, `materialize`) |
> | Stat shape | `%VFS.Stat{type, size, mtime, mode}` — own struct, shaped to virtual-FS semantics. Not `File.Stat` (OS-fs concepts like `inode`/`uid`/`gid` don't apply to git blobs or S3 objects). Follows stdlib `type: atom()` convention. |
> | Errors | Structured `%VFS.Error{kind, path, mount, message}` exception. Pattern match on `:kind` for control flow. Kind atoms follow POSIX (`:enoent`, `:eisdir`, ...). |
> | Read-side primitives | `walk/3` + `stream_read/3`. Sufficient for any bulk operation: grep, mapreduce, fulltext, sync, dedup, backup. |
> | Higher-order ops | Out of v1 core. `grep`/`glob`/`cp`/`mv` belong in a companion package or consumer code; the library stays small on purpose. |
> | Cross-backend pushdown | Deferred to optional secondary protocols (e.g. `VFS.Searchable`, `VFS.ContentAddressed`) when a pattern recurs. v1 has none. |
> | Read/write protocol | Single combined protocol; not split. Read-only-ness is a `capabilities/1` property. |
> | Runtime deps | `:telemetry` only (effectively-stdlib in Elixir; required for the agent-loop observability story). |
> | Cut from v0.1 protocol | `lstat`, `readlink`, `symlink`, `link`, `chmod`, `append_file` — no v1 backend uses them; YAGNI. Add when there's a real consumer. |
> | `VFS.Git` | **Not in this library.** Lives as `defimpl VFS.Mountable, for: Exgit.Repository` inside `:exgit`. |
> | `VFS.Overlay` / `VFS.ReadOnly` | **Not stock impls.** Documented as worked examples; users compose when needed. |
> | S3 backend | Deferred from v1 |
> | Streaming writes | Deferred to v0.2 |
> | Path watching | Out of scope; separate protocol if/when needed |

---

## TL;DR

1. **One protocol, `VFS.Mountable`.** Every backend is a struct that `defimpl`s it. No behaviours. The current code in both `just_bash` and `pyex` already does fake protocol dispatch via `fs.__struct__.read(fs, ...)` — switching to actual protocols deletes that fake dispatch and gives consolidated, fast dispatch tables.
2. **Reads thread state back, not just writes.** This is the single biggest defect in the existing `JustBash.FS.Backend` behaviour and the reason `GitFS.materialize/1` had to exist as a workaround. With `read_file(impl, path) :: {:ok, binary, impl} | {:error, reason}`, a lazy `GitFS` cache is preserved across reads.
3. **Mount-table-as-FS.** The `VFS.t()` struct (mount table + dispatch) itself implements `VFS.Mountable`. Mount tables nest. `LayeredFS` doesn't need to know whether its inner is a single backend or a mount table.
4. **Lazy by default.** `stream_read/3` is the protocol's primary read primitive (returns `Enumerable.t()`). `read_file/2` is a thin helper that runs the stream into a binary. Backends with bytes already in hand return a single-chunk stream from `stream_read`; every backend gets `read_file` for free. This is the substantive shift from the previous draft, where `read_file` was primary and `stream_read` was bolted on.
5. **Tiny v1 surface.** Library ships: protocol, `%VFS{}` mount table, `VFS.Memory`, `VFS.Path`, `VFS.Stat`, `VFS.Error`, `VFS.StreamOptions`, `VFS.Skeleton`, `VFS.Default`. **No `VFS.Git`** (lives as a `defimpl` inside `:exgit`). **No `VFS.Overlay` / `VFS.ReadOnly`** (documented patterns, not stock impls). Caller-provided is one `defimpl`.
6. **Two primitives, anything composes on top.** `walk/3` (lazy tree traversal yielding `{path, stat}`) and `stream_read/3` (lazy per-file byte stream) are the universal read-side primitives. Together they're sufficient to build grep, mapreduce, fulltext indexing, content-addressed dedup, sync, backup, stats — any bulk operation a consumer wants. `grep` and `glob` are consumer-side compositions (or a future companion package), not protocol ops and not library helpers; `%VFS.Match{}` was a smell because it was an op-specific result type leaking into the universal interface. Backend-specific perf optimizations live as backend-specific functions (e.g. `Exgit.FS.grep/4`); cross-backend pushdown for a recurring pattern gets a future optional secondary protocol (`VFS.Searchable`, `VFS.ContentAddressed`, etc.) — not pollution of the core.
7. **Both consumer libs converge on this protocol.** `just_bash` deletes its `FS.Backend` behaviour and its in-memory/RO impls; `pyex` deletes `Pyex.Filesystem` and its `Memory` impl. Both now hold a `VFS.t()` and pass it back to the caller after every operation.

---

## Why protocols, not behaviours (evidence)

The receipts are in the existing code:

```elixir
# pyex/lib/pyex/ctx.ex:835
mod = fs.__struct__
case mod.read(fs, path) do ...

# pyex/lib/pyex/ctx.ex:905
case fs.__struct__.write(fs, path, buffer, mode) do ...

# just_bash/lib/just_bash/fs/fs.ex:82
def mount(%__MODULE__{mounts: mounts} = fs, mountpoint, backend_state) do
  module = backend_state.__struct__
  ...
end
```

This is "I want polymorphism on a struct value" — which is exactly what protocols are for. The behaviour requires every caller to either pre-bundle `{module, state}` tuples or extract the module from `__struct__` at the call site. Both repos do the latter, repeatedly. With a protocol:

```elixir
VFS.Mountable.read_file(fs, path)   # dispatched on fs's struct, no __struct__ pokery
```

Other concrete wins for this codebase:
- **Caller-provided backends become genuinely cheap.** Drop a `defimpl` in your app, done. With behaviours, you're additionally responsible for wiring up `__struct__` extraction or `{mod, state}` plumbing.
- **Protocol consolidation in releases** turns dispatch into compile-time-known function calls — relevant for the hot path in an agent loop (every tool call hits the FS).
- **Decorators don't need to know the inner type.** A user-written read-only or CoW overlay holds an `inner :: term()` (any protocol-implementing struct) and delegates via the protocol. The current `JustBash.FS.ReadOnlyFS` has to store `inner_mod` separately precisely because behaviours don't dispatch on values. (Decorators are documented patterns, not stock impls — see "Worked example patterns" below — but the protocol-vs-behaviour delta is what makes them one-field structs instead of two.)

The one thing protocols give up vs. behaviours: dialyzer can't enforce that an impl exists for every type at compile time. Mitigation: `mix.exs` has `consolidate_protocols: Mix.env() != :test`, and we ship a `VFS.assert_implemented!/1` that raises with a helpful message if a struct shows up without an impl. Plus the impls are all internal struct types we control, so this is mostly a non-issue in practice.

---

## Library shape

```
vfs/
├── lib/
│   ├── vfs.ex                     # Mount-table struct + public API + `defimpl VFS.Mountable, for: VFS`
│   ├── vfs/
│   │   ├── mountable.ex           # The protocol
│   │   ├── path.ex                # Pure path utilities (normalize, dirname, basename, resolve)
│   │   ├── stat.ex                # %VFS.Stat{type, size, mtime, mode}
│   │   ├── memory.ex              # In-memory backend (the only stock impl)
│   │   ├── default.ex             # Default `walk` impl used by Skeleton
│   │   ├── error.ex               # %VFS.Error{kind, path, mount, message} exception
│   │   ├── stream_options.ex      # chunk_size / byte_range / line_range handling
│   │   └── skeleton.ex            # `use VFS.Skeleton` macro for impl authors
└── mix.exs

# mix.exs deps — none required at runtime
# (consumers add :exgit themselves; exgit ships defimpl VFS.Mountable, for: Exgit.Repository)
```

The library has zero non-stdlib runtime deps. `:exgit` takes `:vfs` as an optional dep and ships its own `defimpl`; same pattern for any future S3, FTP, IPFS, etc. backend. This inverts the dependency direction from the previous draft, where vfs knew about exgit; now exgit knows about vfs (which is correct — vfs is the abstraction, exgit is the concrete thing). Per Dave: "I could see the behavior for VFS implemented by ExGit instead. Protocols make this possible."

---

## The protocol

### Result type — `%VFS.Stat{}`

```elixir
defmodule VFS.Stat do
  @moduledoc """
  Metadata for a path in a virtual filesystem.

  Deliberately *not* `File.Stat` from stdlib: that struct is shaped around
  POSIX `stat(2)` for real OS files (`inode`, `uid`, `gid`, `links`,
  `major_device`, `minor_device`). For a virtual filesystem where most
  backends are git blobs, S3 objects, or in-memory maps, those fields are
  meaningless and would be `nil` constantly. Better to have a struct
  shaped to the abstraction.

  Field conventions follow `File.Stat` where they exist (`type: atom()`,
  not `is_file: boolean()`).
  """

  @type t :: %__MODULE__{
          type: :regular | :directory | :symlink | :other,
          size: non_neg_integer(),
          mtime: DateTime.t(),
          mode: non_neg_integer() | nil
        }

  defstruct [:type, :size, :mtime, mode: nil]
end
```

Four fields, no more:

- **`type`** — atom, matching `File.Stat`'s convention. Use `stat.type == :regular`, never `is_file`.
- **`size`** — bytes for files, undefined-but-present for directories (backends usually return 0).
- **`mtime`** — `DateTime.t()`, not Erlang datetime tuple. VFS is a new abstraction; no legacy compatibility burden, so we canonicalize on the modern type. Backends without real mtimes (e.g. content-addressed git blobs) use a deterministic value such as the commit time of the containing tree, or epoch.
- **`mode`** — POSIX permission bits when meaningful (Memory tracks them, exgit returns the tree-entry mode), `nil` when not (S3, in general). Optional and explicitly nullable.

Things deliberately omitted, with reasoning:

- **`atime`, `ctime`** — neither git nor S3 nor an in-memory store has a meaningful access or change time. Real OS-file callers can read `File.stat!/1` directly.
- **`inode`, `links`, `uid`, `gid`, `major_device`, `minor_device`** — POSIX-fs concepts that don't generalize. A git blob has no inode. An S3 object has no uid.
- **`is_symbolic_link: boolean()`** — `type == :symlink` covers it.

If a future backend needs to expose extra metadata (e.g. an exgit mount wanting to expose blob SHA), that's a backend-specific concern; the backend module exposes its own getter (`Exgit.FS.blob_sha(repo, ref, path)`). We don't grow the universal struct for one backend's needs — same principle as keeping `grep` out of the protocol.

### Protocol

```elixir
defprotocol VFS.Mountable do
  @moduledoc """
  Pluggable virtual filesystem. Implementations are plain structs; the
  protocol dispatches on the struct type.

  ## Path contract

  All paths are absolute, already normalized, leading `/`. Backends behave
  as if rooted at `/`. Mount-prefix stripping happens in `VFS` before the
  call reaches a backend impl.

  ## State threading

  *Every* operation — including reads — returns the (possibly updated)
  impl as the last element of the success tuple. Lazy backends (e.g. an
  exgit-backed mount with a partial-clone repo) cache fetched blobs in
  their struct on read; throwing the updated struct away (as the previous
  behaviour-based design did) destroyed those caches. Callers thread the
  new state forward.

  ## Errors

  Structured `%VFS.Error{kind, path, mount, message}` exceptions. `:kind`
  follows POSIX: `:enoent`, `:eexist`, `:eisdir`, `:enotdir`, `:erofs`,
  `:eacces`, `:einval`, `:exdev`, `:eio`, `:eloop`, plus `:enotsup` for
  backends that don't support an op.
  """

  @type t :: struct()
  @type path :: String.t()

  # ── queries — return state because lazy backends mutate cache on read ──

  @spec exists?(t, path) :: {boolean, t}
  def exists?(impl, path)

  @spec stat(t, path) :: {:ok, VFS.Stat.t(), t} | {:error, VFS.Error.t()}
  def stat(impl, path)

  # Bounded backends return a list of names; paginated/unbounded backends
  # return a Stream. Consumers treat the result as an Enumerable.
  @spec readdir(t, path) :: {:ok, Enumerable.t(String.t()), t} | {:error, VFS.Error.t()}
  def readdir(impl, path)

  # ── streaming reads are the primary read API ──
  #
  # `stream_read/3` is the protocol's only file-content read primitive.
  # `VFS.read_file/2` (the helper, not a protocol op) runs this stream into
  # a binary for callers who want eager bytes; backends with a natural eager
  # path return a single-chunk stream. Per Dave: file reads return
  # "something you could pull out lazily as well" — making the lazy form
  # primary means callers never pay for a 1 GiB blob materialization they
  # didn't ask for.
  #
  # The Enumerable emits binary chunks. opts: :chunk_size (default 64 KiB),
  # :byte_range, :line_range. `t` returned in the success tuple is the
  # impl after any header/metadata reads needed to *open* the stream;
  # cache state populated *during* enumeration does not escape the stream
  # (see "cache-eviction caveat" below).
  @spec stream_read(t, path, keyword) :: {:ok, Enumerable.t(binary), t} | {:error, VFS.Error.t()}
  def stream_read(impl, path, opts)

  # ── streaming tree walk ──

  # Emits {path, %VFS.Stat{}}. opts: :max_depth, :include_dirs (default
  # false). Returns a bare Enumerable, not a {:ok, _, t} tuple — the one
  # exception to state threading. `glob` and `grep` are NOT protocol ops —
  # they're consumer-side compositions of this + `stream_read`. Keeping the
  # protocol minimal avoids forcing higher-order result shapes (e.g. a
  # grep-specific `%VFS.Match{}`) into the universal interface.
  @spec walk(t, path, keyword) :: Enumerable.t({path, VFS.Stat.t()})
  def walk(impl, root, opts)

  # ── eager prefetch lever for lazy backends ──

  # No-op for Memory; e.g. Exgit.Repository.materialize/2 for an Exgit-backed
  # mount. Useful when callers know they're about to do a full-tree scan and
  # want to pay the network cost up front rather than per-blob during
  # enumeration.
  @spec materialize(t, keyword) :: {:ok, t} | {:error, VFS.Error.t()}
  def materialize(impl, opts)

  # ── mutations ──

  @spec write_file(t, path, binary, keyword) :: {:ok, t} | {:error, VFS.Error.t()}
  def write_file(impl, path, content, opts)

  @spec mkdir(t, path, keyword) :: {:ok, t} | {:error, VFS.Error.t()}
  def mkdir(impl, path, opts)

  @spec rm(t, path, keyword) :: {:ok, t} | {:error, VFS.Error.t()}
  def rm(impl, path, opts)

  # ── capability introspection — lets callers fast-path or refuse ──

  @spec capabilities(t) :: MapSet.t(capability)
  def capabilities(impl)
end
```

Ten callbacks — that is the entire shipped surface. The draft additionally
sketched `lstat`, `readlink`, `read_file`-as-callback, `append_file`,
`chmod`, `symlink`, and `link`; all were cut before 0.1 (no v1 backend used
them — see the decision table).

Backends that don't support an op return `{:error, %VFS.Error{kind: :enotsup}}`. `capabilities/1` reports the set so callers can avoid trying. Capability atoms: `:read`, `:write`, `:mkdir` (write does not imply mkdir — flat-keyed backends like S3 support `:write` without it), plus pushdown/streaming markers `:native_walk`, `:native_stream_read`, and `:lazy` (the impl benefits from `materialize/2` before bulk reads).

### Skeleton macro for impl authors

```elixir
defmodule VFS.Skeleton do
  @moduledoc """
  Default impls of the optional `VFS.Mountable` ops a backend doesn't
  override. `use VFS.Skeleton` inside a `defimpl` block.

  The required minimum for any backend: `stream_read/3`, `readdir/2`,
  `stat/2`, `exists?/2`, `write_file/4`, `mkdir/3`, `rm/3`,
  `capabilities/1` (read-only backends refuse the mutations with :erofs).
  The skeleton supplies `walk/3` and `materialize/2`.
  """
  defmacro __using__(_opts) do
    quote do
      # ── walk default composed from readdir + stat ──
      def walk(impl, root, opts),   do: VFS.Default.walk(impl, root, opts)
      def materialize(impl, _opts), do: {:ok, impl}

      defoverridable walk: 3, materialize: 2
    end
  end
end
```

The default `walk` lives in `VFS.Default.walk/3` — a lazy depth-first traversal that recursively `readdir`s. The eager read is *not* a protocol op or skeleton default: `VFS.read_file/2` (the public helper) runs `stream_read/3` into a binary, so every backend gets it for free and backends with bytes already in hand return a single-chunk stream. The cache-eviction caveat (cache state populated *during* enumeration doesn't escape the stream) is documented below; `materialize/2` is the lever for callers who need it pre-populated.

### Example: how `:exgit` ships a defimpl (lives in exgit, not vfs)

Exgit takes `:vfs` as an optional dep and ships `defimpl VFS.Mountable, for: Exgit.Repository`. Per Dave: *"I could see the behavior for VFS implemented by ExGit instead. Protocols make this possible."* This is exactly the case protocols are for — vfs declares the abstraction, exgit attaches an impl directly to its own `Repository.t()` struct, no wrapper, no shim.

```elixir
# THIS LIVES IN :exgit, NOT in :vfs (illustrative sketch)
defimpl VFS.Mountable, for: Exgit.Repository do
  use VFS.Skeleton

  # writes refused — git is read-only via this protocol
  def write_file(repo, path, _, _), do: {:error, VFS.Error.new(:erofs, path: path)}
  def mkdir(repo, path, _),         do: {:error, VFS.Error.new(:erofs, path: path)}
  def rm(repo, path, _),            do: {:error, VFS.Error.new(:erofs, path: path)}

  # streaming read — the primary read primitive
  def stream_read(%Exgit.Repository{} = repo, path, opts) do
    ref = repo.default_ref
    case Exgit.FS.read_path(repo, ref, path) do
      {:ok, {_mode, %Exgit.Object.Blob{data: data}}, repo2} ->
        chunk_size = Keyword.get(opts, :chunk_size, 64 * 1024)
        stream = data |> chunk_binary(chunk_size)
        {:ok, stream, repo2}
      {:error, reason} -> {:error, VFS.Error.new(map_error(reason), path: path)}
    end
  end

  # streaming pushdown — walk traverses tree objects without inflating blobs
  def walk(%Exgit.Repository{} = repo, _root, _opts),
    do: Exgit.FS.walk(repo, repo.default_ref)

  # exgit's walk requires an eager repo when scanning the full tree —
  # materialize/2 is the lever
  def materialize(%Exgit.Repository{} = repo, _opts) do
    case Exgit.Repository.materialize(repo, repo.default_ref) do
      {:ok, repo2} -> {:ok, repo2}
      err -> err
    end
  end

  # ...stat, exists?, readdir wrap Exgit.FS too...

  def capabilities(_), do: MapSet.new([:read, :native_walk, :lazy])
end
```

Two things to note about what the defimpl does *not* contain:

1. **No `grep`/`glob` impls.** Those aren't protocol ops (or library helpers). Consumers compose `walk + stream_read + line scan` — correct, lazy, memory-bounded; see "Worked example 1" below.

2. **The pack-internal grep optimization remains accessible as `Exgit.FS.grep/4`** — a backend-specific function on the exgit side. Power users who have an `Exgit.Repository` in hand and need maximum performance call it directly. This is the "escape hatch" pattern: the protocol gives you correctness and abstraction; the backend module gives you peak performance when you need it.

The 1M-file `grep -r TODO /repo` agent case via the protocol: a consumer grep walks tree objects (no blob fetches), then for each path calls `stream_read` (one blob at a time, line-scanned, discarded). Memory bounded to one blob. Correct. Slower than `Exgit.FS.grep/4`'s pack scanner, but the latter is a perf optimization the abstraction doesn't need to absorb.

---

## Primitives — `walk` + `stream_read`, and what builds on them

The protocol's read-side surface is built around two primitives:

- **`walk/3`** — lazy tree traversal yielding `Stream.t({path, %VFS.Stat{}})`. Backend-specific implementations control how cheaply this can be done (exgit walks tree objects without inflating blobs; Memory walks an in-memory map; a future S3 backend uses paginated `ListObjectsV2`).
- **`stream_read/3`** — lazy per-file byte stream yielding chunks. Includes `:byte_range` and `:line_range` opts for partial reads.

Together these are sufficient for any bulk read-side operation a consumer wants to build. The motivating scenario was "1M-file grep on an exgit-backed mount," but the primitives weren't designed for grep — they're designed for *any* bulk traversal that needs to stay memory-bounded and lazy on the per-file axis. Below: three worked examples showing the same primitives compose into different consumer-side operations.

### Worked example 1: `grep` (consumer-side, not in the library)

```elixir
def grep(fs, root, pattern, opts \\ []) do
  fs
  |> VFS.Mountable.walk(root, opts)            # Stream.t({path, stat})
  |> Stream.filter(fn {_, stat} -> stat.type == :regular end)
  |> Stream.flat_map(fn {path, _stat} ->
    case VFS.Mountable.stream_read(fs, path, []) do
      {:ok, byte_stream, _fs2} -> scan_lines(byte_stream, pattern, path, opts)
      _ -> []
    end
  end)
end
```

Returns `Stream.t({path, line_number, line, before_context, after_context})`. Plain tuples — no protocol-level result struct. Memory-bounded: at any moment, at most one file's content is being held.

### Worked example 2: a mapreduce framework

The exact thing Ivar asked about. A consumer can write this as a library on top of `:vfs` without the protocol changing:

```elixir
defmodule MyApp.MapReduce do
  @moduledoc """
  Parallel map-reduce over a VFS. Worker fan-out via Task.async_stream;
  no special protocol support needed beyond walk + stream_read.
  """
  def run(fs, root, map_fn, reduce_fn, acc, opts \\ []) do
    concurrency = Keyword.get(opts, :max_concurrency, System.schedulers_online() * 2)

    fs
    |> VFS.Mountable.walk(root, opts)
    |> Stream.filter(fn {_, stat} -> stat.type == :regular end)
    |> Task.async_stream(
      fn {path, stat} ->
        {:ok, content_stream, _} = VFS.Mountable.stream_read(fs, path, [])
        map_fn.(path, stat, content_stream)
      end,
      max_concurrency: concurrency,
      ordered: false
    )
    |> Stream.flat_map(fn
      {:ok, result} -> [result]
      {:exit, _reason} -> []
    end)
    |> Enum.reduce(acc, reduce_fn)
  end
end

# Usage: count word frequencies across an entire repo
MyApp.MapReduce.run(
  fs,
  "/repo",
  fn _path, _stat, content_stream ->
    content_stream
    |> Stream.flat_map(&String.split(&1, ~r/\W+/))
    |> Enum.frequencies()
  end,
  &Map.merge(&1, &2, fn _k, a, b -> a + b end),
  %{}
)
```

This works on `VFS.Memory`, on `Exgit.Repository`-backed mounts, on a CoW overlay over either, on the `%VFS{}` mount table — anywhere the protocol is implemented. The consumer doesn't care about backend identity. **`walk` and `stream_read` carry the entire weight.**

### Worked example 3: stats / dedup-by-content-hash

```elixir
# Total bytes by extension
fs
|> VFS.Mountable.walk("/", [])
|> Stream.filter(fn {_, s} -> s.type == :regular end)
|> Enum.reduce(%{}, fn {path, stat}, acc ->
  ext = Path.extname(path)
  Map.update(acc, ext, stat.size, &(&1 + stat.size))
end)

# Group files by content hash (dedup)
fs
|> VFS.Mountable.walk("/", [])
|> Stream.filter(fn {_, s} -> s.type == :regular end)
|> Task.async_stream(fn {path, _} ->
  {:ok, stream, _} = VFS.Mountable.stream_read(fs, path, [])
  hash = stream |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1)) |> :crypto.hash_final()
  {hash, path}
end)
|> Stream.map(fn {:ok, x} -> x end)
|> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
|> Enum.filter(fn {_, paths} -> length(paths) > 1 end)
```

Both compositions, no protocol changes.

### When to add a new primitive

The bar for adding a new protocol op: **it can't be expressed efficiently in terms of `walk + stream_read + stat`, and multiple backend types could meaningfully implement it differently.** Some candidates that have come up and where they currently sit:

| Operation | Status | Reasoning |
|---|---|---|
| `glob` (declarative path filter) | Consumer-side, not protocol op | Composes from `walk + path match`. Could become a `:glob` *option* on `walk` in v0.2 if backends with metadata indexes (sqlite-backed, S3) want pushdown. |
| `hash(path)` (content-addressed) | Not in v1 | Git has it natively; nobody else does yet. Future `VFS.ContentAddressed` optional protocol when a second backend gains native hashes. |
| `diff(fs1, fs2)` | Not in v1 | Cross-FS, expensive in general. Caller composes from two walks + comparison. Future `VFS.Diffable` if it recurs. |
| `find(predicate)` (stat-based) | Not in v1 | Caller `Stream.filter`s walk output. Pushdown only matters for backends with metadata indexes; deferred until that comes up. |

The principle: **start with the smallest sufficient set of primitives. Add ops only when the composed version is provably wrong (incorrect, leaks, blows memory) for some real backend.**

### The pushdown escape hatch

For maximum performance on a specific backend, users call backend functions directly:

```elixir
# Goes through the abstraction (correct, slower but bounded memory):
MyApp.Grep.run(fs, "/repo", "TODO") |> Enum.to_list()   # walk + stream_read composition

# Bypasses the abstraction for max perf (only works on exgit-backed):
Exgit.FS.grep(repo, ref, "TODO", []) |> Enum.to_list()
```

Backend-specific functions are not "leaks" in the abstraction — they're the right place for performance optimizations that don't generalize. The protocol gives portability and correctness; the backend module gives peak perf when the user can commit to a specific backend.

### The materialize lever (for lazy backends)

A lazy partial-clone exgit repo will, during a full-tree `walk + stream_read`, fetch blobs on demand — one round trip per blob. Callers who know they're about to iterate the whole tree can pre-warm:

```elixir
{:ok, fs} = VFS.Mountable.materialize(fs, [])   # cheap for non-lazy mounts; pulls blobs for exgit-backed ones
results = MyApp.MapReduce.run(fs, "/", map_fn, reduce_fn, acc)
```

`VFS.Memory`'s `materialize/2` impl is a no-op. An overlay's `materialize/2` recurses into both layers. The mount-table `materialize/2` fans out. Uniform call; only lazy backends actually do network work.

### The cache-eviction caveat

State threading and lazy enumerables don't compose cleanly: a `Stream` from `walk` captures `impl` in a closure, but cache updates that happen inside the stream (e.g. an exgit-backed mount's blob cache populating during `stream_read` calls) don't escape back to the caller. Two ways to handle this:

1. **For one-shot ops** (CLI-style `grep`, mapreduce-then-discard), accept the eviction. The result is still correct — the next operation just won't see the cache the stream populated.
2. **For agent loops** that iterate then re-touch the same files, call `materialize/2` first. Subsequent `read_file` / `stream_read` calls land in the populated cache.

We deliberately don't try to thread state through streams via tricks (`Stream.transform` accumulators, cache-merge callbacks). The cleaner contract: streams are cache-evicting; `materialize/2` is the lever; document and move on.

### What we deliberately don't do in v1

- **`grep`/`glob` anywhere in the library.** Consumer-side compositions of the primitives (originally drafted as `VFS` helpers; cut entirely before 0.1).
- **`%VFS.Match{}` struct.** Plain tuples in helper return values; consumers wrap to their own types if they want one. Avoids leaking op-specific shapes into the core.
- **`VFS.Searchable` / `VFS.ContentAddressed` / `VFS.Diffable` optional protocols.** Deferred to v0.2+ if patterns recur across backends.
- **Streaming writes.** `stream_write/3` is also v0.2 — `Enumerable.t() -> {:ok, impl}`. Default impl will `Enum.into` a buffered `write_file`. Multipart-upload backends override.
- **`tail`-style follow.** Watching a path for changes is a separate concern; `VFS.Watch` if/when needed.
- **Concurrent walk across mounts.** Mount-table iteration concatenates streams sequentially in v1. Parallelizing is a `Task.async_stream` away when a workload shows it matters. (Note: per-file parallelism within a single walk is already available to consumers — see the mapreduce example.)

---

## Mount table — `VFS.t()` itself implements the protocol

```elixir
defmodule VFS do
  defstruct mounts: []
  @type mount :: {mountpoint :: String.t(), backend :: struct()}
  @type t :: %__MODULE__{mounts: [mount()]}

  # ── construction & mount management ──
  def new, do: %__MODULE__{}
  def mount(%__MODULE__{} = vfs, mountpoint, backend), do: ...
  def umount(%__MODULE__{} = vfs, mountpoint), do: ...
  def mounts(%__MODULE__{} = vfs), do: ...

  # ── telemetry-wrapped helpers that delegate to the protocol ──
  # read_file/2 (derived from stream_read), stream_read/3, write_file/4,
  # mkdir/3, rm/3, exists?/2, stat/2, readdir/2, walk/3, materialize/2,
  # capabilities/1 — these exist for ergonomics (callers say
  # `VFS.stream_read(fs, ...)`) and carry the :telemetry instrumentation.
  #
  # `cp`/`mv` were sketched here in the draft and cut: composable from
  # read+write at the consumer, and cross-mount semantics (:exdev) are a
  # consumer-policy decision.
end

defimpl VFS.Mountable, for: VFS do
  # Longest-prefix mount routing, backend state threaded back through the
  # mount tuple — exactly the logic in the existing `JustBash.FS`, but
  # adapted so reads also produce updated state. Errors bubbling up get
  # :path rewritten into the user's namespace and :mount attached.
  def stream_read(%VFS{} = vfs, path, opts) do
    case VFS.__resolve__(vfs, VFS.Path.normalize(path)) do
      {:ok, mountpoint, sub, backend} ->
        case VFS.Mountable.stream_read(backend, sub, opts) do
          {:ok, stream, new_backend} ->
            {:ok, stream, VFS.__put_mount__(vfs, mountpoint, new_backend)}

          {:error, err} ->
            {:error, err |> VFS.Error.put_path(path) |> VFS.Error.put_mount(mountpoint)}
        end

      :no_mount ->
        {:error, VFS.Error.new(:enoent, path: path)}
    end
  end
  # ... etc — readdir, stat, walk, write_file, mkdir, rm all follow the same shape
end
```

Because `VFS` itself is a `VFS.Mountable`, you can mount a `VFS` *inside* a `VFS`. Useful for namespacing (one tenant's mount table mounted at `/tenants/acme/`), and falls out of the design for free.

---

## Worked example patterns (not in v1, documented for reference)

Per Dave's review point 4 — Overlay and ReadOnly aren't stock impls in v1; they're patterns users compose. Including them here so the patterns are concrete and so future contributors have a reference. Either could land later as a stock impl if usage shows the same shape getting reinvented across consumers.

### CoW overlay — the agent staging pattern

The agent-staging primitive: reads check `upper` first, then `lower`; writes go to `upper`; deletes mark a path as a whiteout. A concrete `JustBash.Sandbox.Overlay` (or `Pyex.Sandbox.Overlay`, or wherever the consumer wants it) would look like:

```elixir
defmodule MyApp.Overlay do
  @moduledoc """
  Copy-on-write overlay over any `VFS.Mountable`. Inspect changes with
  `diff/1`. Promote with `commit/1` (requires `lower` writable). Discard
  by dropping the overlay.
  """
  defstruct [:lower, :upper, whiteouts: MapSet.new()]

  def new(lower, upper \\ VFS.Memory.new()),
    do: %__MODULE__{lower: lower, upper: upper}

  def diff(%__MODULE__{} = ov), do: ...                # {added, modified, deleted}
  def commit(%__MODULE__{} = ov), do: ...              # apply diff onto lower
end

defimpl VFS.Mountable, for: MyApp.Overlay do
  use VFS.Skeleton

  def stream_read(%{upper: u, lower: l, whiteouts: w} = ov, path, opts) do
    cond do
      MapSet.member?(w, path) -> {:error, VFS.Error.new(:enoent, path: path)}
      true ->
        case VFS.Mountable.stream_read(u, path, opts) do
          {:ok, s, u2} -> {:ok, s, %{ov | upper: u2}}
          {:error, %VFS.Error{kind: :enoent}} ->
            case VFS.Mountable.stream_read(l, path, opts) do
              {:ok, s, l2} -> {:ok, s, %{ov | lower: l2}}
              other -> other
            end
          other -> other
        end
    end
  end

  def write_file(%{upper: u} = ov, path, content, opts) do
    case VFS.Mountable.write_file(u, path, content, opts) do
      {:ok, u2} -> {:ok, %{ov | upper: u2, whiteouts: MapSet.delete(ov.whiteouts, path)}}
      err -> err
    end
  end

  def rm(%{whiteouts: w} = ov, path, _opts),
    do: {:ok, %{ov | whiteouts: MapSet.put(w, path)}}

  # ...readdir merges upper + lower entries minus whiteouts; stat/exists? same
  def capabilities(%{upper: u, lower: l}) do
    # intersect lower's read-side caps with upper's write-side caps
    ...
  end
end
```

Agent-loop usage (the pattern that motivated the original "layered/CoW" requirement):

```elixir
base_fs = VFS.new()
          |> VFS.mount("/repo", some_exgit_repo)        # lower: read-only git
          |> VFS.mount("/tmp",  VFS.Memory.new())       # lower: scratch

sandbox = MyApp.Overlay.new(base_fs)

{result, sandbox} = JustBash.exec(JustBash.new(fs: sandbox), "sed -i 's/foo/bar/' /repo/README.md")

{added, modified, deleted} = MyApp.Overlay.diff(sandbox)
# drop sandbox to discard, or MyApp.Overlay.commit(sandbox) to promote
```

### Read-only wrapper

Even simpler — a one-field wrapper that refuses every mutation. Backends can also self-declare read-only via `capabilities/1`; the wrapper is for cases where you want to *take* a writable backend and *enforce* read-only at the type level for one code path.

```elixir
defmodule MyApp.ReadOnly do
  defstruct [:inner]
  def new(inner), do: %__MODULE__{inner: inner}
end

defimpl VFS.Mountable, for: MyApp.ReadOnly do
  use VFS.Skeleton
  # All reads delegate to inner; threading inner through %ReadOnly{}.
  def stream_read(%{inner: i} = ro, path, opts) do
    case VFS.Mountable.stream_read(i, path, opts) do
      {:ok, s, i2} -> {:ok, s, %{ro | inner: i2}}
      err -> err
    end
  end
  # ...stat, exists?, readdir, walk all delegate similarly...

  # All writes refused regardless of inner's capabilities
  def write_file(_, path, _, _), do: {:error, VFS.Error.new(:erofs, path: path)}
  def mkdir(_, path, _),         do: {:error, VFS.Error.new(:erofs, path: path)}
  def rm(_, path, _),            do: {:error, VFS.Error.new(:erofs, path: path)}

  def capabilities(%{inner: i}),
    do: VFS.Mountable.capabilities(i) |> MapSet.intersection(MapSet.new([:read, :native_walk, :native_stream_read, :lazy]))
end
```

---

## Migration deltas

### `just_bash`

Net deletion: `lib/just_bash/fs/backend.ex`, `lib/just_bash/fs/in_memory_fs.ex`, `lib/just_bash/fs/read_only_fs.ex` — gone, replaced by `:vfs` dep.

`lib/just_bash/fs/fs.ex` shrinks to a thin shim or is deleted entirely (callers use `VFS` directly). For a softer migration, keep `JustBash.FS` as `defmodule JustBash.FS, do: defdelegate(..., to: VFS)` for one or two minor releases.

`JustBash.exec/2` already accepts `fs:` in opts. The only behavioural change: it now returns `{result, vfs}` (it already does — see `lib/just_bash.ex`), but the inner `vfs` is now a `%VFS{}` not a `%JustBash.FS{}`.

### `pyex`

`Pyex.Filesystem` (the behaviour) — deleted.
`Pyex.Filesystem.Memory` — deleted (replaced by `VFS.Memory`).
`Pyex.Filesystem.S3` — kept temporarily as a leaf `defimpl VFS.Mountable, for: Pyex.Filesystem.S3` until a stock `VFS.S3` lands. Code-wise, just porting the existing `:read`/`:write` callbacks onto the new protocol surface — no functional change. (The pyex S3 impl is currently the only S3 backend in the stack, and we want to keep that capability working through the migration.)

`Pyex.Ctx`'s `:filesystem` field becomes a `VFS.t()`. `open_handle` / `close_handle` rewrite their `mod = fs.__struct__; mod.read(fs, path)` dispatch to `VFS.Mountable.read_file(fs, path)` — and now thread the returned `fs` back through `ctx`, which they already do.

Two API gaps to reconcile between the two consumer libs:

| Concern | `JustBash.FS.Backend` | `Pyex.Filesystem` | `VFS.Mountable` (proposed) |
|---|---|---|---|
| Content type | `binary()` | `String.t()` | `binary()` (UTF-8 strings are binaries) |
| Errors | `:enoent`, etc. | `"FileNotFoundError: ..."` strings | POSIX atoms (pyex formats Python errors at its boundary) |
| Write modes | `write_file` + `append_file` | `write(:write \| :append \| :read)` | `write_file` + `append_file` (cleaner; `:read` was nonsensical in `write/4`) |
| Symlinks/chmod | yes | no | yes; pyex impls just won't call them |
| Stat shape | bare map with `is_file`/`is_directory` | bare map | `%VFS.Stat{}` (own struct, virtual-FS-shaped); `type` atom replaces booleans |

Pyex's "format Python error string in the FS layer" pattern was wrong — error formatting belongs at the Python-binding boundary, not in the FS. The migration removes it.

---

## What this fixes vs. `feat/mountable-virtual-filesystem-core`

1. **Lazy-backend cache eviction on every read.** `GitFS` had to grow a `materialize/1` workaround precisely because `read_file` couldn't return the cache-updated `Repository.t()`. The new protocol makes the cache survive reads naturally.
2. **Decorators are one-field, not two.** A user-written read-only or CoW wrapper becomes one field (`inner :: any-impl`) where the existing `ReadOnlyFS` has two (`inner_mod`, `inner_state`). Pattern documented in "Worked example patterns" rather than shipped as a stock impl.
3. **Caller-provided is one `defimpl`.** No `__struct__` extraction, no `{module, state}` plumbing; just implement the protocol on your struct.
4. **One library, two consumers.** Right now `pyex` and `just_bash` have completely independent FS abstractions. The new design is the explicit shared dep that lets agents pass FS state between them.
5. **Mount tables nest** because `VFS` itself implements `VFS.Mountable`. Free composition.

The mount-routing logic, longest-prefix matching, synthetic mountpoint stat/readdir merging, cross-mount `mv` returning `:exdev`, symlink-crosses-mount detection — all of that ports over directly. The current implementation in `lib/just_bash/fs/fs.ex` is sound; we're just changing the dispatch substrate underneath it.

---

## Deferred from v1

These were considered and deliberately punted; flagging here so the reviewer doesn't have to ask:

- **`VFS.S3` backend.** When added, will wrap Req's built-in S3 support. Until then, `Pyex.Filesystem.S3` ports forward as a leaf `defimpl VFS.Mountable, for: Pyex.Filesystem.S3` so we don't lose S3 capability during migration.
- **Streaming writes (`stream_write/3`).** Not needed for the agent loop in v1. Would land alongside `VFS.S3`'s multipart upload — at that point the protocol grows one callback with a default `Enum.into` impl.
- **`tail`-style path watching.** Different concern from VFS streaming; would get its own protocol (`VFS.Watch`) when a real workload demands it.
- **Concurrent walk across mounts.** The `%VFS{}` mount-table `walk` concatenates per-mount streams sequentially in v1. Parallelizing is a `Task.async_stream` away when a workload shows it matters.
- **Read/write protocol split.** Single `VFS.Mountable` protocol with `:erofs`/`:enotsup` returns and `capabilities/1` introspection, not separate `Read`/`Write` protocols. The split would force every dispatcher op to pick which protocol to dispatch to, and we'd lose protocol consolidation wins.

## v1 deliverable checklist

**`ivarvong/vfs`:**
- [ ] Repo created, `mix new` skeleton, zero non-stdlib deps
- [ ] `VFS.Stat`, `VFS.Path` (pure path utilities)
- [ ] `VFS.Mountable` protocol — 10 callbacks; Skeleton supplies `walk`/`materialize` defaults
- [ ] `VFS.Default` — fallback impl for `walk`
- [ ] `VFS.Skeleton` — `use`-able macro that wires the defaults
- [ ] `VFS.Memory` — in-memory backend (port + simplification of `JustBash.FS.InMemoryFS`)
- [ ] `%VFS{}` mount-table struct + `defimpl VFS.Mountable, for: VFS` (port of existing routing logic from `feat/mountable-virtual-filesystem-core`)
- [ ] ~~`grep` and `glob` helpers~~ — cut from the library; consumer-side compositions (see "Worked example 1")
- [ ] Conformance test suite parametrized over impls — every backend runs the same test set
- [ ] README documenting the worked-example patterns (CoW overlay, read-only wrapper) so users know how to compose

**`ivarvong/exgit`:**
- [ ] Add `:vfs` as an optional dep
- [ ] `defimpl VFS.Mountable, for: Exgit.Repository` — wraps `Exgit.FS` with native pushdowns for `walk`/`materialize`
- [ ] Tests confirming the defimpl passes vfs's conformance suite (read-only subset)

**`elixir-ai-tools/just_bash`:**
- [ ] PR deleting `lib/just_bash/fs/{backend,in_memory_fs,read_only_fs}.ex` and the `feat/mountable-virtual-filesystem-core` proposal
- [ ] Add `:vfs` dep; `JustBash.exec/2`'s `:fs` opt becomes a `VFS.t()`
- [ ] `JustBash.FS` shim module aliasing to `VFS` for one minor release if needed for migration smoothness

**`ivarvong/pyex`:**
- [ ] PR deleting `Pyex.Filesystem` behaviour and `Pyex.Filesystem.Memory` impl
- [ ] `Pyex.Filesystem.S3` ported as `defimpl VFS.Mountable, for: Pyex.Filesystem.S3` (leaf-only; no behaviour)
- [ ] `Pyex.Ctx`'s `:filesystem` field becomes a `VFS.t()`; ctx threads it through

**Integration:**
- [ ] End-to-end test exercising the agent loop — bash writes via `VFS`, pyex reads via `VFS`, FS state threaded through both — over (a) `VFS.Memory`, (b) `%VFS{}` with a memory mount + an `Exgit.Repository` mount
