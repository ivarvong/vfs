defmodule VFS.Test.LinksBackend do
  @moduledoc false
  # Minimal backend that accepts `symlink/3` and `link/3` calls so that
  # `VFS`'s defimpl success branches for these ops are exercised. Tracks
  # nothing; just acknowledges.

  defstruct symlinks: %{}, links: %{}
  @type t :: %__MODULE__{symlinks: map(), links: map()}

  @spec new() :: t()
  def new, do: %__MODULE__{}
end

defimpl VFS.Mountable, for: VFS.Test.LinksBackend do
  use VFS.Skeleton

  alias VFS.Stat
  alias VFS.Test.LinksBackend

  @epoch DateTime.from_unix!(0)

  def exists?(b, _), do: {true, b}

  def stat(b, "/"), do: {:ok, %Stat{type: :directory, size: 0, mtime: @epoch}, b}
  def stat(b, _), do: {:ok, %Stat{type: :regular, size: 0, mtime: @epoch}, b}

  def readdir(b, _), do: {:ok, [], b}
  def stream_read(b, _, _), do: {:ok, [""], b}
  def read_file(b, _), do: {:ok, "", b}
  def write_file(b, _, _, _), do: {:ok, b}
  def append_file(b, _, _), do: {:ok, b}
  def mkdir(b, _, _), do: {:ok, b}
  def rm(b, _, _), do: {:ok, b}

  def symlink(%LinksBackend{} = b, target, link_path) do
    {:ok, %{b | symlinks: Map.put(b.symlinks, link_path, target)}}
  end

  def link(%LinksBackend{} = b, existing, new) do
    {:ok, %{b | links: Map.put(b.links, new, existing)}}
  end

  def capabilities(_), do: MapSet.new([:read, :write, :symlinks, :hardlinks])
end
