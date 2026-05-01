defmodule VFS.Skeleton do
  @moduledoc """
  Default implementations of `VFS.Mountable` ops a backend doesn't override.

  `use VFS.Skeleton` inside a `defimpl` block to inherit:

    * `read_file/2`     — runs `stream_read/3` and concatenates chunks. Override
                          for an eager fast path (e.g. `VFS.Memory`).
    * `walk/3`          — composed via `VFS.Default.walk/3`. Override for native
                          pushdown (e.g. exgit walking tree objects directly).
    * `materialize/2`   — no-op; override for lazy backends.
    * `append_file/3`   — `read_file/2` + concatenate + `write_file/4`.
    * `chmod/3`, `symlink/3`, `link/3`, `readlink/2` — return `{:error, :enotsup}`.
    * `lstat/2`         — delegates to `stat/2`.

  All defaults are `defoverridable`, so backends shadow with native impls.

  ## Required minimum

  The skeleton provides defaults; the backend must still implement:
  `stream_read/3`, `readdir/2`, `stat/2`, `exists?/2`, `write_file/4`,
  `mkdir/3`, `rm/3`, `capabilities/1`. Read-only backends typically refuse
  the mutations with `{:error, :erofs}`.

  ## Example

      defimpl VFS.Mountable, for: MyBackend do
        use VFS.Skeleton

        def stream_read(%MyBackend{} = b, path, _opts), do: ...
        def readdir(%MyBackend{} = b, path), do: ...
        def stat(%MyBackend{} = b, path), do: ...
        def exists?(%MyBackend{} = b, path), do: ...
        def write_file(%MyBackend{} = b, path, content, _opts), do: ...
        def mkdir(%MyBackend{} = b, path, _opts), do: ...
        def rm(%MyBackend{} = b, path, _opts), do: ...
        def capabilities(_), do: MapSet.new([:read, :write])
      end
  """

  defmacro __using__(_opts) do
    quote do
      def read_file(impl, path) do
        case stream_read(impl, path, []) do
          {:ok, stream, impl2} ->
            {:ok, stream |> Enum.to_list() |> IO.iodata_to_binary(), impl2}

          {:error, _} = err ->
            err
        end
      end

      def walk(impl, root, opts), do: VFS.Default.walk(impl, root, opts)

      def materialize(impl, _opts), do: {:ok, impl}

      def append_file(impl, path, content) when is_binary(content) do
        case read_file(impl, path) do
          {:ok, existing, impl2} ->
            write_file(impl2, path, existing <> content, [])

          {:error, :enoent} ->
            write_file(impl, path, content, [])

          {:error, _} = err ->
            err
        end
      end

      def chmod(_impl, _path, _mode), do: {:error, :enotsup}
      def symlink(_impl, _target, _link), do: {:error, :enotsup}
      def link(_impl, _existing, _new), do: {:error, :enotsup}
      def readlink(_impl, _path), do: {:error, :enotsup}
      def lstat(impl, path), do: stat(impl, path)

      defoverridable read_file: 2,
                     walk: 3,
                     materialize: 2,
                     append_file: 3,
                     chmod: 3,
                     symlink: 3,
                     link: 3,
                     readlink: 2,
                     lstat: 2
    end
  end
end
