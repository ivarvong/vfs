defmodule VFS.Memory do
  @moduledoc """
  In-memory `VFS.Mountable` backend.

  Files live in a `tree` map (`%{path => binary}`); explicitly-created
  empty directories live in a `dirs` `MapSet`; `mtimes` tracks
  modification times.

  Directories are recognized in two ways:

    1. **Explicit** — created via `mkdir/3`, recorded in `dirs`.
    2. **Implicit** — at least one file or explicit dir under them.

  Both kinds satisfy `stat/2` and `readdir/2`. Removing the last child of an
  implicit directory makes it disappear; an explicit directory persists
  until removed via `rm/3` with `recursive: true`.

  ## Construction

      iex> mem = VFS.Memory.new(%{"/foo/bar" => "hello"})
      iex> {:ok, "hello", _mem} = VFS.read_file(mem, "/foo/bar")
      iex> :ok
      :ok

  Use the helpers in `VFS` (e.g. `VFS.read_file/2`, `VFS.walk/3`) for
  telemetry-instrumented access. Direct protocol calls bypass instrumentation.
  """

  @type t :: %__MODULE__{
          tree: %{VFS.Path.t() => binary},
          dirs: MapSet.t(VFS.Path.t()),
          mtimes: %{VFS.Path.t() => DateTime.t()}
        }

  defstruct tree: %{}, dirs: MapSet.new(), mtimes: %{}

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

  alias VFS.Error
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
           mtime: Map.get(mem.mtimes, p, @epoch)
         }, mem}

      directory?(mem, p) ->
        {:ok, %Stat{type: :directory, size: 0, mtime: Map.get(mem.mtimes, p, @epoch)}, mem}

      true ->
        {:error, Error.new(:enoent, path: p)}
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
        {:error, Error.new(:enotdir, path: p)}

      true ->
        {:error, Error.new(:enoent, path: p)}
    end
  end

  def stream_read(%Memory{} = mem, path, opts) do
    p = VFS.Path.normalize(path)

    case Map.fetch(mem.tree, p) do
      {:ok, content} ->
        with {:ok, sliced} <- apply_byte_range(content, opts),
             {:ok, sliced} <- apply_line_range(sliced, opts) do
          chunk_size = Keyword.get(opts, :chunk_size, 64 * 1024)
          {:ok, chunk_stream(sliced, chunk_size), mem}
        else
          {:error, reason} -> {:error, Error.new(reason, path: p)}
        end

      :error ->
        if directory?(mem, p),
          do: {:error, Error.new(:eisdir, path: p)},
          else: {:error, Error.new(:enoent, path: p)}
    end
  end

  def write_file(%Memory{} = mem, path, content, _opts) when is_binary(content) do
    p = VFS.Path.normalize(path)

    if directory?(mem, p) do
      {:error, Error.new(:eisdir, path: p)}
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
        {:error, Error.new(:eexist, path: p)}

      MapSet.member?(mem.dirs, p) ->
        {:error, Error.new(:eexist, path: p)}

      parents? ->
        {:ok, mkdir_p(mem, p)}

      not directory?(mem, VFS.Path.dirname(p)) ->
        {:error, Error.new(:enoent, path: p)}

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
             mtimes: Map.delete(mem.mtimes, p)
         }}

      directory?(mem, p) and p != "/" ->
        if recursive?,
          do: {:ok, rm_recursive(mem, p)},
          else: {:error, Error.new(:eisdir, path: p)}

      p == "/" ->
        if recursive?, do: {:ok, %Memory{}}, else: {:error, Error.new(:eisdir, path: p)}

      true ->
        {:error, Error.new(:enoent, path: p)}
    end
  end

  def capabilities(_), do: MapSet.new([:read, :write])

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

  # ── byte_range / line_range slicing ──

  defp apply_byte_range(content, opts) do
    case Keyword.fetch(opts, :byte_range) do
      :error ->
        {:ok, content}

      {:ok, {start, length}}
      when is_integer(start) and start >= 0 and is_integer(length) and length >= 0 ->
        {:ok, slice_bytes(content, start, length)}

      {:ok, _bad} ->
        {:error, :einval}
    end
  end

  defp slice_bytes(content, start, _length) when start >= byte_size(content), do: <<>>

  defp slice_bytes(content, start, length) do
    available = byte_size(content) - start
    take = min(length, available)
    :binary.part(content, start, take)
  end

  defp apply_line_range(content, opts) do
    case Keyword.fetch(opts, :line_range) do
      :error ->
        {:ok, content}

      {:ok, {first, last}} when is_integer(first) and first >= 1 ->
        slice_lines(content, first, last)

      {:ok, _bad} ->
        {:error, :einval}
    end
  end

  defp slice_lines(content, first, last) when last == :end or is_integer(last) do
    lines = String.split(content, "\n")
    last_idx = if last == :end, do: length(lines), else: last
    sliced = lines |> Enum.slice((first - 1)..(last_idx - 1)//1) |> Enum.join("\n")
    {:ok, sliced}
  end

  defp slice_lines(_content, _first, _last), do: {:error, :einval}

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
