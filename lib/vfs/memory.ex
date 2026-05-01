defmodule VFS.Memory do
  @moduledoc """
  In-memory `VFS.Mountable` backend.

  Files live in a `tree` map (`%{path => binary}`); explicitly-created
  empty directories live in a `dirs` `MapSet`; `modes` and `mtimes` track
  permission bits and timestamps.

  Directories are recognized in two ways:

    1. **Explicit** — created via `mkdir/3`, recorded in `dirs`.
    2. **Implicit** — at least one file or explicit dir under them.

  Both kinds satisfy `stat/2` and `readdir/2`. Removing the last child of an
  implicit directory makes it disappear; an explicit directory persists
  until removed via `rm/3` with `recursive: true`.

  ## Construction

      iex> mem = VFS.Memory.new(%{"/foo/bar" => "hello"})
      iex> {:ok, "hello", _mem} = VFS.Mountable.read_file(mem, "/foo/bar")
      iex> :ok
      :ok

  Use the helpers in `VFS` (e.g. `VFS.read_file/2`, `VFS.walk/3`) for
  telemetry-instrumented access. Direct protocol calls bypass instrumentation.
  """

  @type t :: %__MODULE__{
          tree: %{VFS.Path.t() => binary},
          dirs: MapSet.t(VFS.Path.t()),
          modes: %{VFS.Path.t() => non_neg_integer()},
          mtimes: %{VFS.Path.t() => DateTime.t()}
        }

  defstruct tree: %{}, dirs: MapSet.new(), modes: %{}, mtimes: %{}

  @doc """
  Build a fresh in-memory FS, optionally seeded with files.

  ## Examples

      iex> mem = VFS.Memory.new()
      iex> mem.tree
      %{}

      iex> mem = VFS.Memory.new(%{"/a.txt" => "hi"})
      iex> Map.fetch!(mem.tree, "/a.txt")
      "hi"
  """
  @spec new(%{optional(String.t()) => binary}) :: t()
  def new(initial \\ %{}) when is_map(initial) do
    now = DateTime.utc_now()

    Enum.reduce(initial, %__MODULE__{}, fn {path, content}, mem ->
      norm = VFS.Path.normalize(path)

      %{
        mem
        | tree: Map.put(mem.tree, norm, content),
          mtimes: Map.put(mem.mtimes, norm, now)
      }
    end)
  end
end

defimpl VFS.Mountable, for: VFS.Memory do
  use VFS.Skeleton

  alias VFS.Memory
  alias VFS.Stat

  @epoch DateTime.from_unix!(0)

  def exists?(%Memory{} = mem, path) do
    p = VFS.Path.normalize(path)
    {Map.has_key?(mem.tree, p) or directory?(mem, p), mem}
  end

  def stat(%Memory{} = mem, path) do
    p = VFS.Path.normalize(path)

    cond do
      Map.has_key?(mem.tree, p) ->
        content = Map.fetch!(mem.tree, p)

        {:ok,
         %Stat{
           type: :regular,
           size: byte_size(content),
           mtime: Map.get(mem.mtimes, p, @epoch),
           mode: Map.get(mem.modes, p)
         }, mem}

      directory?(mem, p) ->
        {:ok,
         %Stat{
           type: :directory,
           size: 0,
           mtime: Map.get(mem.mtimes, p, @epoch),
           mode: Map.get(mem.modes, p)
         }, mem}

      true ->
        {:error, :enoent}
    end
  end

  def readdir(%Memory{} = mem, path) do
    p = VFS.Path.normalize(path)

    cond do
      directory?(mem, p) ->
        prefix = if p == "/", do: "/", else: p <> "/"

        names =
          (mem.tree |> Map.keys() |> children_under(prefix)) ++
            (mem.dirs |> MapSet.to_list() |> children_under(prefix))

        {:ok, names |> Enum.uniq() |> Enum.sort(), mem}

      Map.has_key?(mem.tree, p) ->
        {:error, :enotdir}

      true ->
        {:error, :enoent}
    end
  end

  def stream_read(%Memory{} = mem, path, opts) do
    p = VFS.Path.normalize(path)

    case Map.fetch(mem.tree, p) do
      {:ok, content} ->
        chunk_size = Keyword.get(opts, :chunk_size, 64 * 1024)
        {:ok, chunk_stream(content, chunk_size), mem}

      :error ->
        if directory?(mem, p), do: {:error, :eisdir}, else: {:error, :enoent}
    end
  end

  # Eager override — Memory has bytes already; skip the stream-then-concat round trip.
  def read_file(%Memory{} = mem, path) do
    p = VFS.Path.normalize(path)

    case Map.fetch(mem.tree, p) do
      {:ok, content} ->
        {:ok, content, mem}

      :error ->
        if directory?(mem, p), do: {:error, :eisdir}, else: {:error, :enoent}
    end
  end

  def write_file(%Memory{} = mem, path, content, _opts) when is_binary(content) do
    p = VFS.Path.normalize(path)

    if directory?(mem, p) do
      {:error, :eisdir}
    else
      now = DateTime.utc_now()

      {:ok,
       %{
         mem
         | tree: Map.put(mem.tree, p, content),
           mtimes: Map.put(mem.mtimes, p, now)
       }}
    end
  end

  def mkdir(%Memory{} = mem, path, opts) do
    p = VFS.Path.normalize(path)
    parents? = Keyword.get(opts, :parents, false)

    cond do
      Map.has_key?(mem.tree, p) ->
        {:error, :eexist}

      MapSet.member?(mem.dirs, p) ->
        {:error, :eexist}

      parents? ->
        {:ok, mkdir_p(mem, p)}

      not directory?(mem, VFS.Path.dirname(p)) ->
        {:error, :enoent}

      true ->
        {:ok, put_dir(mem, p)}
    end
  end

  def rm(%Memory{} = mem, path, opts) do
    p = VFS.Path.normalize(path)
    recursive? = Keyword.get(opts, :recursive, false)

    cond do
      Map.has_key?(mem.tree, p) ->
        {:ok,
         %{
           mem
           | tree: Map.delete(mem.tree, p),
             mtimes: Map.delete(mem.mtimes, p),
             modes: Map.delete(mem.modes, p)
         }}

      directory?(mem, p) and p != "/" ->
        if recursive?, do: {:ok, rm_recursive(mem, p)}, else: {:error, :eisdir}

      p == "/" ->
        if recursive?, do: {:ok, %Memory{}}, else: {:error, :eisdir}

      true ->
        {:error, :enoent}
    end
  end

  def chmod(%Memory{} = mem, path, mode) when is_integer(mode) and mode >= 0 do
    p = VFS.Path.normalize(path)

    if Map.has_key?(mem.tree, p) or directory?(mem, p) do
      {:ok, %{mem | modes: Map.put(mem.modes, p, mode)}}
    else
      {:error, :enoent}
    end
  end

  def capabilities(_), do: MapSet.new([:read, :write, :chmod, :append])

  # ── helpers ──

  defp directory?(_mem, "/"), do: true

  defp directory?(%Memory{tree: tree, dirs: dirs}, path) do
    MapSet.member?(dirs, path) or has_descendants?(Map.keys(tree), path) or
      has_descendants?(MapSet.to_list(dirs), path)
  end

  defp has_descendants?(paths, dir) do
    prefix = dir <> "/"
    Enum.any?(paths, &String.starts_with?(&1, prefix))
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

  defp put_dir(mem, path) do
    now = DateTime.utc_now()
    %{mem | dirs: MapSet.put(mem.dirs, path), mtimes: Map.put(mem.mtimes, path, now)}
  end

  defp mkdir_p(mem, "/"), do: mem

  defp mkdir_p(mem, path) do
    parent = VFS.Path.dirname(path)
    mem = mkdir_p(mem, parent)

    if MapSet.member?(mem.dirs, path) or directory?(mem, path) do
      mem
    else
      put_dir(mem, path)
    end
  end

  defp rm_recursive(%Memory{} = mem, path) do
    prefix = path <> "/"

    %{
      mem
      | tree: drop_prefixed(mem.tree, path, prefix),
        dirs: drop_prefixed_set(mem.dirs, path, prefix),
        modes: drop_prefixed(mem.modes, path, prefix),
        mtimes: drop_prefixed(mem.mtimes, path, prefix)
    }
  end

  defp drop_prefixed(map, exact, prefix) do
    Map.reject(map, fn {k, _} -> k == exact or String.starts_with?(k, prefix) end)
  end

  defp drop_prefixed_set(set, exact, prefix) do
    set
    |> MapSet.to_list()
    |> Enum.reject(fn k -> k == exact or String.starts_with?(k, prefix) end)
    |> MapSet.new()
  end

  defp chunk_stream(<<>>, _size), do: []

  defp chunk_stream(content, chunk_size) when chunk_size > 0 do
    Stream.unfold(content, fn
      <<>> ->
        nil

      bin when byte_size(bin) <= chunk_size ->
        {bin, <<>>}

      bin ->
        <<chunk::binary-size(^chunk_size), rest::binary>> = bin
        {chunk, rest}
    end)
  end
end
