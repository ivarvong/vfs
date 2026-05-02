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

  Errors during traversal (e.g. a `readdir` that fails because the directory
  was deleted between calls) are silent — the offending subtree is skipped
  and walk continues. Callers needing strict error surfacing should `stat`
  the root first, or compose their own walk on `readdir`.

  Cache state populated during enumeration does not escape — see the
  cache-eviction caveat in `VFS.Mountable`.
  """
  @spec walk(VFS.Mountable.t(), VFS.Mountable.path(), keyword) :: Enumerable.t()
  def walk(impl, root, opts) do
    max_depth = Keyword.get(opts, :max_depth, :infinity)
    include_dirs = Keyword.get(opts, :include_dirs, false)

    Stream.resource(
      fn -> [{root, 0}] end,
      fn
        [] ->
          {:halt, nil}

        [{path, depth} | rest] ->
          step(impl, path, depth, rest, max_depth, include_dirs)
      end,
      fn _ -> :ok end
    )
  end

  defp step(impl, path, depth, rest, max_depth, include_dirs) do
    case VFS.Mountable.stat(impl, path) do
      {:ok, %VFS.Stat{type: :directory} = stat, _impl2} ->
        children = directory_children(impl, path, depth, max_depth)
        emitted = if include_dirs, do: [{path, stat}], else: []
        # children bounded by branching factor; depth-first via stack-prepend.
        # vfs:audit-ok
        new_queue = children ++ rest
        {emitted, new_queue}

      {:ok, stat, _impl2} ->
        {[{path, stat}], rest}

      {:error, _reason} ->
        {[], rest}
    end
  end

  defp directory_children(impl, path, depth, max_depth) do
    if depth_ok?(depth, max_depth) do
      case VFS.Mountable.readdir(impl, path) do
        {:ok, names, _impl} ->
          Enum.map(names, fn name -> {VFS.Path.join(path, name), depth + 1} end)

        {:error, _} ->
          []
      end
    else
      []
    end
  end

  defp depth_ok?(_depth, :infinity), do: true
  defp depth_ok?(depth, max) when is_integer(max), do: depth < max
end
