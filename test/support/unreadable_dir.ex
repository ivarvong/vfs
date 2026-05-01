defmodule VFS.Test.UnreadableDir do
  @moduledoc false
  # Test backend with one directory `/borked` that reports as a directory
  # in `stat/2` but errors `:eacces` from `readdir/2`. Used to verify that
  # `VFS.Default.walk/3` silently skips subtrees whose readdir fails.

  @type t :: %__MODULE__{}
  defstruct []

  @spec new() :: t()
  def new, do: %__MODULE__{}
end

defimpl VFS.Mountable, for: VFS.Test.UnreadableDir do
  use VFS.Skeleton

  alias VFS.Stat

  @epoch DateTime.from_unix!(0)

  def exists?(%VFS.Test.UnreadableDir{} = b, _), do: {true, b}

  def stat(%VFS.Test.UnreadableDir{} = b, "/"),
    do: {:ok, %Stat{type: :directory, size: 0, mtime: @epoch}, b}

  def stat(%VFS.Test.UnreadableDir{} = b, "/borked"),
    do: {:ok, %Stat{type: :directory, size: 0, mtime: @epoch}, b}

  def stat(%VFS.Test.UnreadableDir{} = b, "/ok"),
    do: {:ok, %Stat{type: :regular, size: 0, mtime: @epoch}, b}

  def stat(_b, "/locked"), do: {:error, :eacces}

  def stat(_b, _), do: {:error, :enoent}

  def readdir(%VFS.Test.UnreadableDir{} = b, "/"), do: {:ok, ["borked", "ok"], b}
  def readdir(_b, "/borked"), do: {:error, :eacces}
  def readdir(_b, _), do: {:error, :enoent}

  def stream_read(_b, _, _), do: {:error, :enotsup}
  def read_file(_, _), do: {:error, :enotsup}
  def append_file(_, _, _), do: {:error, :erofs}
  def write_file(_, _, _, _), do: {:error, :erofs}
  def mkdir(_, _, _), do: {:error, :erofs}
  def rm(_, _, _), do: {:error, :erofs}

  def capabilities(_), do: MapSet.new([:read])
end
