defprotocol VFS.Mountable do
  @moduledoc """
  Pluggable virtual filesystem.

  Implementations are plain structs; the protocol dispatches on the struct
  type. Backend authors typically use `VFS.Skeleton` inside their `defimpl`
  block to inherit defaults for ops they don't natively support, then
  override the ones they do.

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

  POSIX-style atoms:

    * `:enoent`   — path doesn't exist
    * `:eexist`   — path already exists (e.g. `mkdir` collision)
    * `:eisdir`   — expected a file, got a directory
    * `:enotdir`  — expected a directory, got a file
    * `:erofs`    — the mount or wrapper is read-only
    * `:enotsup`  — the backend doesn't support this op
    * `:eacces`   — permission denied
    * `:einval`   — bad argument (e.g. malformed path)
    * `:exdev`    — cross-mount op that can't be atomic
    * `:eio`      — underlying I/O failure
    * `:eloop`    — symlink loop

  `:erofs` vs `:enotsup`: a read-only-wrapping defimpl refuses writes with
  `:erofs` (the *mount* is read-only); a backend that simply doesn't
  implement an op (e.g. `chmod` on S3) returns `:enotsup`.
  """

  @typedoc "Any struct that implements `VFS.Mountable`."
  @type t :: struct()

  @typedoc "An absolute, normalized path (see `VFS.Path`)."
  @type path :: String.t()

  @typedoc "A POSIX-style error atom."
  @type reason ::
          :enoent
          | :eexist
          | :eisdir
          | :enotdir
          | :erofs
          | :enotsup
          | :eacces
          | :einval
          | :exdev
          | :eio
          | :eloop

  @typedoc "Capability flags reported by `capabilities/1`."
  @type capability ::
          :read
          | :write
          | :symlinks
          | :hardlinks
          | :chmod
          | :append
          | :native_walk
          | :native_glob
          | :native_grep
          | :native_stream_read
          | :lazy

  # ── queries — return state because lazy backends mutate cache on read ──

  @doc "Return whether `path` exists, plus the (possibly cache-updated) impl."
  @spec exists?(t, path) :: {boolean, t}
  def exists?(impl, path)

  @doc "Return metadata for `path`."
  @spec stat(t, path) :: {:ok, VFS.Stat.t(), t} | {:error, reason}
  def stat(impl, path)

  @doc "Like `stat/2` but does not follow a final symlink."
  @spec lstat(t, path) :: {:ok, VFS.Stat.t(), t} | {:error, reason}
  def lstat(impl, path)

  @doc "Return entries directly under directory `path`, sorted, names only (no leading slash)."
  @spec readdir(t, path) :: {:ok, [String.t()], t} | {:error, reason}
  def readdir(impl, path)

  @doc "Resolve a symlink one level."
  @spec readlink(t, path) :: {:ok, path, t} | {:error, reason}
  def readlink(impl, path)

  # ── streaming reads are the primary read API ──

  @doc """
  Open `path` for streaming read. Returns an `t:Enumerable.t/0` that emits
  binary chunks. Options:

    * `:chunk_size`  — default `64 * 1024`
    * `:byte_range`  — `{start, length}` (inclusive of `start`, length bytes)
    * `:line_range`  — `{first, last}` 1-based, inclusive

  The returned impl reflects state needed to *open* the stream; cache state
  populated during enumeration does not escape (see `walk/3` caveat).
  """
  @spec stream_read(t, path, keyword) :: {:ok, Enumerable.t(), t} | {:error, reason}
  def stream_read(impl, path, opts)

  @doc """
  Eagerly read `path` into a binary. Default impl (via `VFS.Skeleton`) runs
  `stream_read/3` into a binary; backends with a naturally-eager path (e.g.
  `VFS.Memory`) override for a fast path.
  """
  @spec read_file(t, path) :: {:ok, binary, t} | {:error, reason}
  def read_file(impl, path)

  # ── streaming tree walk ──

  @doc """
  Lazily walk the tree under `root`. Returns an `t:Enumerable.t/0` that emits
  `{path, %VFS.Stat{}}` tuples. Options:

    * `:max_depth`        — `:infinity` (default) or non-neg integer
    * `:include_dirs`     — emit directory entries themselves (default `false`)
    * `:follow_symlinks`  — default `false`

  Returns a bare `t:Enumerable.t/0`, not a `{:ok, _, t}` tuple. Cache state
  populated during enumeration does not escape; call `materialize/2` first
  for agent loops that re-touch files after a walk.
  """
  @spec walk(t, path, keyword) :: Enumerable.t()
  def walk(impl, root, opts)

  # ── eager prefetch lever for lazy backends ──

  @doc """
  Pre-warm any internal cache. No-op for non-lazy backends. Lazy backends
  (e.g. partial-clone exgit repos) use this to avoid per-blob round-trips
  during a subsequent bulk traversal.
  """
  @spec materialize(t, keyword) :: {:ok, t} | {:error, reason}
  def materialize(impl, opts)

  # ── mutations ──

  @doc "Write `content` to `path`. Options reserved for future use."
  @spec write_file(t, path, binary, keyword) :: {:ok, t} | {:error, reason}
  def write_file(impl, path, content, opts)

  @doc "Append `content` to `path`. Creates the file if it doesn't exist."
  @spec append_file(t, path, binary) :: {:ok, t} | {:error, reason}
  def append_file(impl, path, content)

  @doc """
  Create a directory at `path`. Options:

    * `:parents` — create missing intermediate directories (`mkdir -p`)
  """
  @spec mkdir(t, path, keyword) :: {:ok, t} | {:error, reason}
  def mkdir(impl, path, opts)

  @doc """
  Remove `path`. Options:

    * `:recursive` — remove a directory and all contents (default `false`).
      Without `:recursive`, `rm` on a directory returns `{:error, :eisdir}`.
  """
  @spec rm(t, path, keyword) :: {:ok, t} | {:error, reason}
  def rm(impl, path, opts)

  @doc "Set permission bits on `path`."
  @spec chmod(t, path, non_neg_integer) :: {:ok, t} | {:error, reason}
  def chmod(impl, path, mode)

  @doc "Create a symlink at `link_path` pointing to `target`."
  @spec symlink(t, path, path) :: {:ok, t} | {:error, reason}
  def symlink(impl, target, link_path)

  @doc "Create a hard link at `new` to `existing`."
  @spec link(t, path, path) :: {:ok, t} | {:error, reason}
  def link(impl, existing, new)

  # ── introspection ──

  @doc "Return the set of capabilities this impl supports."
  @spec capabilities(t) :: MapSet.t(capability)
  def capabilities(impl)
end
