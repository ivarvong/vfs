defmodule VFS.Skeleton do
  @moduledoc """
  Default implementations of the optional `VFS.Mountable` ops a backend
  doesn't override.

  `use VFS.Skeleton` inside a `defimpl` block to inherit:

    * `walk/3`        — composed via `VFS.Default.walk/3`. Override for
                        native pushdown (e.g. exgit walking tree objects
                        directly).
    * `materialize/2` — no-op; override for lazy backends.

  Both are `defoverridable`, so backends shadow with native impls.

  ## Required minimum

  The skeleton provides defaults for `walk/3` and `materialize/2`. The
  backend must still implement: `stream_read/3`, `readdir/2`, `stat/2`,
  `exists?/2`, `write_file/4`, `mkdir/3`, `rm/3`, `capabilities/1`.
  Read-only backends typically refuse the mutations with
  `{:error, VFS.Error.new(:erofs, ...)}`.
  """

  defmacro __using__(_opts) do
    quote do
      def walk(impl, root, opts), do: VFS.Default.walk(impl, root, opts)

      def materialize(impl, _opts), do: {:ok, impl}

      defoverridable walk: 3, materialize: 2
    end
  end
end
