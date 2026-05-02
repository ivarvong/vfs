defmodule VFS.Test.LazyDir do
  @moduledoc false
  # An "infinite directory" backend: `readdir/2` returns a `Stream` of
  # entry names produced lazily. Demonstrates that the protocol now
  # accommodates paginated S3-style listings and unbounded virtual
  # namespaces (e.g. `/integers/0`, `/integers/1`, ...).
  #
  # Layout:
  #
  #   /                     directory (synthetic)
  #   /integers/0           regular file, content "0"
  #   /integers/1           regular file, content "1"
  #   /integers/2           regular file, content "2"
  #   ...                   (infinite)
  #
  # `readdir("/integers")` returns `Stream.iterate(0, &(&1 + 1)) |> Stream.map(...)`,
  # which yields names forever. Consumers use `Stream.take/2` to bound it.

  defstruct []
  @type t :: %__MODULE__{}

  @spec new() :: t()
  def new, do: %__MODULE__{}
end

defimpl VFS.Mountable, for: VFS.Test.LazyDir do
  use VFS.Skeleton

  alias VFS.Error
  alias VFS.Stat

  @epoch DateTime.from_unix!(0)

  def exists?(b, "/"), do: {true, b}
  def exists?(b, "/integers"), do: {true, b}

  def exists?(b, "/integers/" <> rest) do
    {match?({_, ""}, Integer.parse(rest)), b}
  end

  def exists?(b, _), do: {false, b}

  def stat(b, "/"), do: {:ok, %Stat{type: :directory, size: 0, mtime: @epoch}, b}
  def stat(b, "/integers"), do: {:ok, %Stat{type: :directory, size: 0, mtime: @epoch}, b}

  def stat(b, "/integers/" <> rest = path) do
    case Integer.parse(rest) do
      {n, ""} ->
        {:ok, %Stat{type: :regular, size: byte_size(Integer.to_string(n)), mtime: @epoch}, b}

      _ ->
        {:error, Error.new(:enoent, path: path)}
    end
  end

  def stat(_b, path), do: {:error, Error.new(:enoent, path: path)}

  def readdir(b, "/") do
    {:ok, ["integers"], b}
  end

  def readdir(b, "/integers") do
    # Infinite stream — the whole point of this backend.
    stream = Stream.iterate(0, &(&1 + 1)) |> Stream.map(&Integer.to_string/1)
    {:ok, stream, b}
  end

  def readdir(_b, path), do: {:error, Error.new(:enoent, path: path)}

  def stream_read(b, "/integers/" <> rest = path, _opts) do
    case Integer.parse(rest) do
      {n, ""} -> {:ok, [Integer.to_string(n)], b}
      _ -> {:error, Error.new(:enoent, path: path)}
    end
  end

  def stream_read(_b, path, _opts), do: {:error, Error.new(:enoent, path: path)}

  def write_file(_, p, _, _), do: {:error, Error.new(:erofs, path: p)}
  def mkdir(_, p, _), do: {:error, Error.new(:erofs, path: p)}
  def rm(_, p, _), do: {:error, Error.new(:erofs, path: p)}

  def capabilities(_), do: MapSet.new([:read])
end
