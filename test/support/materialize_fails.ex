defmodule VFS.Test.MaterializeFails do
  @moduledoc false
  # Test backend whose `materialize/2` returns `{:error, %VFS.Error{kind: :eio}}`.
  # Used to verify that `VFS`'s mount-table `materialize` halts and propagates
  # the first error.

  defstruct []
  @type t :: %__MODULE__{}

  @spec new() :: t()
  def new, do: %__MODULE__{}
end

defimpl VFS.Mountable, for: VFS.Test.MaterializeFails do
  use VFS.Skeleton

  alias VFS.Error

  def exists?(b, _), do: {false, b}
  def stat(_, path), do: {:error, Error.new(:enoent, path: path)}
  def readdir(_, path), do: {:error, Error.new(:enoent, path: path)}
  def stream_read(_, path, _), do: {:error, Error.new(:enoent, path: path)}
  def write_file(_, path, _, _), do: {:error, Error.new(:erofs, path: path)}
  def mkdir(_, path, _), do: {:error, Error.new(:erofs, path: path)}
  def rm(_, path, _), do: {:error, Error.new(:erofs, path: path)}
  def materialize(_, _), do: {:error, Error.new(:eio)}
  def capabilities(_), do: MapSet.new([:read, :lazy])
end
