defmodule VFS.Stat do
  @moduledoc """
  Metadata for a path in a virtual filesystem.

  Deliberately *not* `File.Stat`: that struct is shaped around POSIX `stat(2)`
  for real OS files (`inode`, `uid`, `gid`, `links`, `major_device`,
  `minor_device`). For virtual backends — git blobs, S3 objects, in-memory
  maps — those fields are meaningless and would be `nil` constantly. Better
  to have a struct shaped to the abstraction.

  Fields follow `File.Stat` conventions where they exist (`type :: atom()`,
  not `is_file :: boolean()`).

  ## Fields

    * `:type`  — one of `:regular`, `:directory`, `:symlink`, `:other`.
    * `:size`  — bytes for files; backends typically return `0` for directories.
    * `:mtime` — `DateTime.t()`. Backends without real mtimes (e.g. content-addressed
      git blobs) use a deterministic value such as the containing tree's commit time
      or epoch.
    * `:mode`  — POSIX permission bits when meaningful, `nil` when not (e.g. S3).
  """

  @typedoc "The kind of filesystem entry."
  @type type :: :regular | :directory | :symlink | :other

  @type t :: %__MODULE__{
          type: type(),
          size: non_neg_integer(),
          mtime: DateTime.t(),
          mode: non_neg_integer() | nil
        }

  @enforce_keys [:type, :size, :mtime]
  defstruct [:type, :size, :mtime, mode: nil]

  @doc """
  Build a regular-file stat. Convenience constructor for backends that always
  set `type: :regular` and don't track mode.

  ## Examples

      iex> VFS.Stat.regular(42, ~U[2026-05-01 12:00:00Z])
      %VFS.Stat{type: :regular, size: 42, mtime: ~U[2026-05-01 12:00:00Z], mode: nil}
  """
  @spec regular(non_neg_integer(), DateTime.t(), non_neg_integer() | nil) :: t()
  def regular(size, mtime, mode \\ nil) when is_integer(size) and size >= 0 do
    %__MODULE__{type: :regular, size: size, mtime: mtime, mode: mode}
  end

  @doc """
  Build a directory stat.

  ## Examples

      iex> VFS.Stat.directory(~U[2026-05-01 12:00:00Z])
      %VFS.Stat{type: :directory, size: 0, mtime: ~U[2026-05-01 12:00:00Z], mode: nil}
  """
  @spec directory(DateTime.t(), non_neg_integer() | nil) :: t()
  def directory(mtime, mode \\ nil) do
    %__MODULE__{type: :directory, size: 0, mtime: mtime, mode: mode}
  end
end
