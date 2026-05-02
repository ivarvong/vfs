defmodule VFS.Test.UnreadableDir do
  @moduledoc false
  # Test backend with one directory `/borked` that reports as a directory
  # in `stat/2` but errors `:eacces` from `readdir/2`. Used to verify that
  # `VFS.Default.walk/3` silently skips subtrees whose readdir fails, plus
  # error pass-through from leaf backends to the mount-table dispatcher.

  @type t :: %__MODULE__{}
  defstruct []

  @spec new() :: t()
  def new, do: %__MODULE__{}
end

defimpl VFS.Mountable, for: VFS.Test.UnreadableDir do
  use VFS.Skeleton

  alias VFS.Error
  alias VFS.Stat

  @epoch DateTime.from_unix!(0)

  def exists?(%VFS.Test.UnreadableDir{} = b, _), do: {true, b}

  def stat(%VFS.Test.UnreadableDir{} = b, "/"),
    do: {:ok, %Stat{type: :directory, size: 0, mtime: @epoch}, b}

  def stat(%VFS.Test.UnreadableDir{} = b, "/borked"),
    do: {:ok, %Stat{type: :directory, size: 0, mtime: @epoch}, b}

  def stat(%VFS.Test.UnreadableDir{} = b, "/ok"),
    do: {:ok, %Stat{type: :regular, size: 0, mtime: @epoch}, b}

  def stat(_b, "/locked"), do: {:error, Error.new(:eacces, path: "/locked")}

  def stat(_b, path), do: {:error, Error.new(:enoent, path: path)}

  def readdir(%VFS.Test.UnreadableDir{} = b, "/"), do: {:ok, ["borked", "ok"], b}
  def readdir(_b, "/borked"), do: {:error, Error.new(:eacces, path: "/borked")}
  def readdir(_b, path), do: {:error, Error.new(:enoent, path: path)}

  def stream_read(_b, path, _), do: {:error, Error.new(:enotsup, path: path)}
  def write_file(_, path, _, _), do: {:error, Error.new(:erofs, path: path)}
  def mkdir(_, path, _), do: {:error, Error.new(:erofs, path: path)}
  def rm(_, path, _), do: {:error, Error.new(:erofs, path: path)}

  def capabilities(_), do: MapSet.new([:read])
end
