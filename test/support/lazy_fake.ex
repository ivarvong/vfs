defmodule VFS.Test.LazyFake do
  @moduledoc false
  # A read-only `VFS.Mountable` whose struct counts cache hits and misses,
  # used to verify state threading. Reading a file the first time is a miss
  # (and populates the cache); reading the same file again with state
  # threaded back is a hit. Throwing the returned impl away forces every
  # read to be a miss.

  @type t :: %__MODULE__{
          source: %{VFS.Path.t() => binary},
          cache: %{VFS.Path.t() => binary},
          hits: non_neg_integer(),
          misses: non_neg_integer()
        }

  defstruct source: %{}, cache: %{}, hits: 0, misses: 0

  @spec new(%{optional(String.t()) => binary}) :: t()
  def new(source \\ %{}) when is_map(source) do
    normalized = for {k, v} <- source, into: %{}, do: {VFS.Path.normalize(k), v}
    %__MODULE__{source: normalized}
  end
end

defimpl VFS.Mountable, for: VFS.Test.LazyFake do
  use VFS.Skeleton

  alias VFS.Stat
  alias VFS.Test.LazyFake

  @epoch DateTime.from_unix!(0)

  def exists?(%LazyFake{source: source} = lf, path) do
    p = VFS.Path.normalize(path)
    {Map.has_key?(source, p) or has_descendants?(source, p), lf}
  end

  def stat(%LazyFake{source: source} = lf, path) do
    p = VFS.Path.normalize(path)

    cond do
      Map.has_key?(source, p) ->
        size = source |> Map.fetch!(p) |> byte_size()
        {:ok, %Stat{type: :regular, size: size, mtime: @epoch}, lf}

      p == "/" or has_descendants?(source, p) ->
        {:ok, %Stat{type: :directory, size: 0, mtime: @epoch}, lf}

      true ->
        {:error, :enoent}
    end
  end

  def readdir(%LazyFake{source: source} = lf, path) do
    p = VFS.Path.normalize(path)

    if p == "/" or has_descendants?(source, p) do
      prefix = if p == "/", do: "/", else: p <> "/"

      names =
        source
        |> Map.keys()
        |> children_under(prefix)
        |> Enum.uniq()
        |> Enum.sort()

      {:ok, names, lf}
    else
      if Map.has_key?(source, p), do: {:error, :enotdir}, else: {:error, :enoent}
    end
  end

  def stream_read(%LazyFake{source: source} = lf, path, _opts) do
    p = VFS.Path.normalize(path)

    case Map.fetch(source, p) do
      {:ok, content} ->
        if Map.has_key?(lf.cache, p) do
          :telemetry.execute([:vfs, :cache, :hit], %{}, %{path: p, impl: LazyFake})
          {:ok, [content], %{lf | hits: lf.hits + 1}}
        else
          :telemetry.execute([:vfs, :cache, :miss], %{}, %{path: p, impl: LazyFake})
          {:ok, [content], %{lf | cache: Map.put(lf.cache, p, content), misses: lf.misses + 1}}
        end

      :error ->
        if has_descendants?(source, p), do: {:error, :eisdir}, else: {:error, :enoent}
    end
  end

  # Eager fast-path also goes through the cache-counting path.
  def read_file(%LazyFake{} = lf, path) do
    case stream_read(lf, path, []) do
      {:ok, [content], lf2} -> {:ok, content, lf2}
      {:error, _} = err -> err
    end
  end

  def write_file(_, _, _, _), do: {:error, :erofs}
  def append_file(_, _, _), do: {:error, :erofs}
  def mkdir(_, _, _), do: {:error, :erofs}
  def rm(_, _, _), do: {:error, :erofs}

  def materialize(%LazyFake{source: source} = lf, _opts) do
    {:ok, %{lf | cache: source}}
  end

  def capabilities(_), do: MapSet.new([:read, :lazy])

  defp has_descendants?(source, dir) do
    prefix = if dir == "/", do: "/", else: dir <> "/"
    Enum.any?(Map.keys(source), &String.starts_with?(&1, prefix))
  end

  defp children_under(paths, prefix) do
    Enum.flat_map(paths, fn p ->
      if p != prefix and String.starts_with?(p, prefix) do
        rest = String.replace_prefix(p, prefix, "")
        [rest |> String.split("/", parts: 2) |> hd()]
      else
        []
      end
    end)
  end
end
