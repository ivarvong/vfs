defmodule VFS.Test.InfiniteTree do
  @moduledoc false
  # An infinite virtual filesystem with bounded directory width.
  #
  # Every directory has exactly two entries:
  #
  #   * `"file"`   — a regular file whose content is the directory path
  #   * `"subdir"` — a subdirectory containing the same shape
  #
  # `readdir` always returns `["file", "subdir"]` (sorted, finite — 2 entries).
  # The tree itself has unbounded depth, so walking yields:
  #
  #     /file
  #     /subdir/file
  #     /subdir/subdir/file
  #     /subdir/subdir/subdir/file
  #     ...
  #
  # The depth-first traversal in `VFS.Default.walk/3` pops `"file"` before
  # `"subdir"` at each level (alphabetical sort), so files are yielded
  # before recursing — the stream emits one file per level forever.

  defstruct []
  @type t :: %__MODULE__{}

  @spec new() :: t()
  def new, do: %__MODULE__{}
end

defimpl VFS.Mountable, for: VFS.Test.InfiniteTree do
  use VFS.Skeleton

  alias VFS.Error
  alias VFS.Stat

  @epoch DateTime.from_unix!(0)

  def exists?(b, _), do: {true, b}

  def stat(b, "/") do
    {:ok, %Stat{type: :directory, size: 0, mtime: @epoch}, b}
  end

  def stat(b, path) do
    case Path.basename(path) do
      "file" -> {:ok, %Stat{type: :regular, size: byte_size(path), mtime: @epoch}, b}
      _ -> {:ok, %Stat{type: :directory, size: 0, mtime: @epoch}, b}
    end
  end

  def readdir(b, _path), do: {:ok, ["file", "subdir"], b}

  def stream_read(b, path, _opts) do
    case Path.basename(path) do
      "file" -> {:ok, [path], b}
      _ -> {:error, Error.new(:eisdir, path: path)}
    end
  end

  def write_file(_, path, _, _), do: {:error, Error.new(:erofs, path: path)}
  def mkdir(_, path, _), do: {:error, Error.new(:erofs, path: path)}
  def rm(_, path, _), do: {:error, Error.new(:erofs, path: path)}

  def capabilities(_), do: MapSet.new([:read])
end
