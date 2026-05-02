defmodule VFS.Default do
  @moduledoc """
  Fallback implementations of `VFS.Mountable` ops, composed from the
  required primitives. Used by `VFS.Skeleton` to fill in defaults for
  backends that don't override.
  """

  @doc """
  Default `walk/3` — lazy, depth-first traversal composed from `stat/2` and
  `readdir/2`. Returns a `Stream` of `{path, %VFS.Stat{}}` tuples.

  Options:

    * `:max_depth`     — `:infinity` (default) or a non-neg integer
    * `:include_dirs`  — emit directory entries themselves (default `false`)

  ## Laziness contract

  The traversal is fully lazy: `Stream.take/2` halts as soon as the
  consumer has enough, and **the underlying `readdir/2` is consumed
  one entry at a time**. This means:

    * Unbounded directories work. A backend whose `readdir/2` returns
      a `Stream` of arbitrary length (e.g. a paginated S3 lister, a
      virtual `/integers/N` namespace) composes correctly with
      `walk |> Stream.take(N)` — only the first N entries' worth of
      directory work is performed.
    * Deep trees work. The traversal is recursive but each recursion
      produces a `Stream`, so an infinite-depth tree is bounded by
      what the consumer takes.

  ## Errors

  Errors during traversal (e.g. a `readdir` that fails because the
  directory was deleted between calls) are silent — the offending
  subtree is skipped and walk continues. Callers needing strict error
  surfacing should `stat` the root first or compose their own walk.

  Cache state populated during enumeration does not escape — see the
  cache-eviction caveat in `VFS.Mountable`.
  """
  @spec walk(VFS.Mountable.t(), VFS.Mountable.path(), keyword) :: Enumerable.t()
  def walk(impl, root, opts) do
    max_depth = Keyword.get(opts, :max_depth, :infinity)
    include_dirs = Keyword.get(opts, :include_dirs, false)

    walk_at(impl, root, 0, max_depth, include_dirs)
  end

  # Recursive Stream-returning walk. Each call:
  #
  #   - For a regular file: returns a one-element list `[{path, stat}]`.
  #     Lists are Enumerables, so they compose with `Stream.flat_map`.
  #   - For a directory: returns a `Stream.concat` of (a) optional
  #     self-emission and (b) `Stream.flat_map` over the readdir output,
  #     calling `walk_at` recursively for each child.
  #   - For an error (incl. depth cap or readdir failure): returns `[]`.
  #
  # Critically: `Stream.flat_map` is lazy. Each child is realized only
  # when the consumer demands the next item. That is what makes walk
  # compose with `Stream.take/2` over an unbounded readdir.
  defp walk_at(impl, path, depth, max_depth, include_dirs) do
    case VFS.Mountable.stat(impl, path) do
      {:ok, %VFS.Stat{type: :directory} = stat, _impl2} ->
        directory_stream(impl, path, depth, max_depth, include_dirs, stat)

      {:ok, stat, _impl2} ->
        [{path, stat}]

      {:error, _reason} ->
        []
    end
  end

  defp directory_stream(impl, path, depth, max_depth, include_dirs, stat) do
    self_emission = if include_dirs, do: [{path, stat}], else: []

    if depth_ok?(depth, max_depth) do
      case VFS.Mountable.readdir(impl, path) do
        {:ok, names, _impl} ->
          children =
            Stream.flat_map(names, fn name ->
              walk_at(impl, VFS.Path.join(path, name), depth + 1, max_depth, include_dirs)
            end)

          Stream.concat(self_emission, children)

        {:error, _} ->
          self_emission
      end
    else
      self_emission
    end
  end

  defp depth_ok?(_depth, :infinity), do: true
  defp depth_ok?(depth, max) when is_integer(max), do: depth < max
end
