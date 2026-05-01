defmodule VFS.Test.MaterializeFails do
  @moduledoc false
  # Test backend whose `materialize/2` returns `{:error, :eio}`. Used to
  # verify that `VFS`'s mount-table `materialize` halts and propagates
  # the first error.

  defstruct []
  @type t :: %__MODULE__{}

  @spec new() :: t()
  def new, do: %__MODULE__{}
end

defimpl VFS.Mountable, for: VFS.Test.MaterializeFails do
  use VFS.Skeleton

  def exists?(b, _), do: {false, b}
  def stat(_, _), do: {:error, :enoent}
  def readdir(_, _), do: {:error, :enoent}
  def stream_read(_, _, _), do: {:error, :enoent}
  def read_file(_, _), do: {:error, :enoent}
  def append_file(_, _, _), do: {:error, :erofs}
  def write_file(_, _, _, _), do: {:error, :erofs}
  def mkdir(_, _, _), do: {:error, :erofs}
  def rm(_, _, _), do: {:error, :erofs}
  def materialize(_, _), do: {:error, :eio}
  def capabilities(_), do: MapSet.new([:read, :lazy])
end
