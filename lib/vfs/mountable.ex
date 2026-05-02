defprotocol VFS.Mountable do
  @moduledoc """
  Pluggable virtual filesystem.

  Implementations are plain structs; the protocol dispatches on the struct
  type. Backend authors typically use `VFS.Skeleton` inside their `defimpl`
  block to inherit defaults for `walk/3` and `materialize/2`, then override
  whichever they want native impls for.

  ## Path contract

  All paths reaching a backend are absolute, already normalized, with a
  leading `/`. Backends behave as if rooted at `/`. Mount-prefix stripping
  happens in `VFS`'s defimpl before the call reaches a leaf backend.

  ## State threading

  *Every* operation — including reads — returns the (possibly updated)
  impl as the last element of its success tuple. Lazy backends (e.g. an
  exgit-backed mount with a partial-clone repo) cache fetched data in their
  struct on read; throwing the updated struct away destroys those caches.
  Callers thread the new state forward.

  The one exception is `walk/3`, which returns a bare `t:Enumerable.t/0`.
  Cache state populated during enumeration does not escape — call
  `materialize/2` first if you need the cache primed before iteration.

  ## Errors

  All errors are `%VFS.Error{}` exceptions. Pattern match on `:kind` for
  flow control:

      case VFS.read_file(fs, path) do
        {:ok, bin, fs} -> ...
        {:error, %VFS.Error{kind: :enoent}} -> ...
        {:error, %VFS.Error{kind: :eisdir}} -> ...
      end

  See `VFS.Error` for the full set of `:kind` values.
  """

  @typedoc "Any struct that implements `VFS.Mountable`."
  @type t :: struct()

  @typedoc "An absolute, normalized path (see `VFS.Path`)."
  @type path :: String.t()

  @typedoc "Capability flags reported by `capabilities/1`."
  @type capability ::
          :read
          | :write
          | :native_walk
          | :native_stream_read
          | :lazy

  # ── queries — return state because lazy backends mutate cache on read ──

  @doc "Return whether `path` exists, plus the (possibly cache-updated) impl."
  @spec exists?(t, path) :: {boolean, t}
  def exists?(impl, path)

  @doc "Return metadata for `path`."
  @spec stat(t, path) :: {:ok, VFS.Stat.t(), t} | {:error, VFS.Error.t()}
  def stat(impl, path)

  @doc """
  Return entries directly under directory `path` — names only, no leading
  slash, no path separators within names.

  Returns an `t:Enumerable.t/0` of strings. Backends with bounded
  directories should return a list (the simplest Enumerable; `length/1`
  and `Enum.sort/1` work natively on it). Backends with paginated or
  unbounded listings (S3 with many keys, a database-backed store, a
  virtual `/integers/N` namespace) should return a `Stream`. Consumers
  should treat the result as an Enumerable: use `Enum.to_list/1` or
  `Stream.take/2` as appropriate; do not assume `length/1` works.

  Order: bounded backends should return entries in lexicographic order
  by convention (matches POSIX, S3 ListObjects). Unbounded backends
  document their order in the impl's moduledoc.
  """
  @spec readdir(t, path) :: {:ok, Enumerable.t(String.t()), t} | {:error, VFS.Error.t()}
  def readdir(impl, path)

  @doc """
  Open `path` for streaming read. Returns an `t:Enumerable.t/0` that emits
  binary chunks. Options:

    * `:chunk_size`  — default `64 * 1024`
    * `:byte_range`  — `{start, length}` — start is 0-based, returns up to
      `length` bytes starting at `start`
    * `:line_range`  — `{first, last}` — 1-based, inclusive line numbers;
      `last` may be `:end` to read to EOF

  The returned impl reflects state needed to *open* the stream; cache state
  populated during enumeration does not escape (see `walk/3` caveat).
  """
  @spec stream_read(t, path, keyword) ::
          {:ok, Enumerable.t(binary), t} | {:error, VFS.Error.t()}
  def stream_read(impl, path, opts)

  # ── streaming tree walk ──

  @doc """
  Lazily walk the tree under `root`. Returns an `t:Enumerable.t/0` that emits
  `{path, %VFS.Stat{}}` tuples. Options:

    * `:max_depth`        — `:infinity` (default) or non-neg integer
    * `:include_dirs`     — emit directory entries themselves (default `false`)

  Returns a bare `t:Enumerable.t/0`, not a `{:ok, _, t}` tuple. Cache state
  populated during enumeration does not escape; call `materialize/2` first
  for agent loops that re-touch files after a walk.

  Default-implementation traversal is depth-first. `Stream.take/2` halts the
  traversal as soon as the consumer has enough — composes lazily over
  arbitrarily deep (even infinite-depth) trees so long as `readdir/2`
  returns finite per-directory lists.
  """
  @spec walk(t, path, keyword) :: Enumerable.t({path, VFS.Stat.t()})
  def walk(impl, root, opts)

  # ── eager prefetch lever for lazy backends ──

  @doc """
  Pre-warm any internal cache. No-op for non-lazy backends. Lazy backends
  (e.g. partial-clone exgit repos) use this to avoid per-blob round-trips
  during a subsequent bulk traversal.
  """
  @spec materialize(t, keyword) :: {:ok, t} | {:error, VFS.Error.t()}
  def materialize(impl, opts)

  # ── mutations ──

  @doc "Write `content` to `path`. Options reserved for future use."
  @spec write_file(t, path, binary, keyword) :: {:ok, t} | {:error, VFS.Error.t()}
  def write_file(impl, path, content, opts)

  @doc """
  Create a directory at `path`. Options:

    * `:parents` — create missing intermediate directories (`mkdir -p`)
  """
  @spec mkdir(t, path, keyword) :: {:ok, t} | {:error, VFS.Error.t()}
  def mkdir(impl, path, opts)

  @doc """
  Remove `path`. Options:

    * `:recursive` — remove a directory and all contents (default `false`).
      Without `:recursive`, `rm` on a directory returns
      `{:error, %VFS.Error{kind: :eisdir}}`.
  """
  @spec rm(t, path, keyword) :: {:ok, t} | {:error, VFS.Error.t()}
  def rm(impl, path, opts)

  # ── introspection ──

  @doc "Return the set of capabilities this impl supports."
  @spec capabilities(t) :: MapSet.t(capability)
  def capabilities(impl)
end
