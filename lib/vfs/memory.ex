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

  Raises `ArgumentError` if the seed is malformed:

    * The literal `"/"` cannot be a file (root is always a directory).
    * No two paths can be in a strict path-segment-prefix relationship
      (e.g. `%{"/a" => "...", "/a/b" => "..."}` is rejected — `/a`
      cannot simultaneously be a regular file and a directory).

  Validation runs at construction so the resulting backend is internally
  consistent: `stat`, `readdir`, and `read_file` agree on every path.
  Without validation, externally-provided seeds (config files, DB dumps,
  LLM-generated inputs) could put the FS into a state that no sequence
  of writes could ever produce.

  ## Examples

      iex> mem = VFS.Memory.new()
      iex> mem.tree
      %{}

      iex> mem = VFS.Memory.new(%{"/a.txt" => "hi"})
      iex> Map.fetch!(mem.tree, "/a.txt")
      "hi"

      iex> VFS.Memory.new(%{"/a" => "f", "/a/b" => "c"})
      ** (ArgumentError) VFS.Memory seed has conflicting paths: "/a" is a file but "/a/b" places a child under it. A path cannot be both a file and a directory.
  """
  @spec new(%{optional(String.t()) => binary}) :: t()
  def new(initial \\ %{}) when is_map(initial) do
    normalized =
      for {path, content} <- initial, into: %{} do
        {VFS.Path.normalize(path), content}
      end

    :ok = validate_seed!(normalized)

    now = DateTime.utc_now()

    Enum.reduce(normalized, %__MODULE__{}, fn {path, content}, mem ->
      %{
        mem
        | tree: Map.put(mem.tree, path, content),
          mtimes: Map.put(mem.mtimes, path, now)
      }
    end)
  end

  # Reject seeds that would produce contradictory state.
  #
  # 1. Root key as a file: `/` is always a directory.
  # 2. File / descendant collision: if path A is a file and path B is
  #    under A (i.e. starts with `A/`), A is simultaneously a file and
  #    a directory, which `stat` and `readdir` cannot agree on.
  defp validate_seed!(normalized) do
    if Map.has_key?(normalized, "/") do
      raise ArgumentError,
            "VFS.Memory seed cannot contain \"/\" as a file — root is always a directory."
    end

    paths = Map.keys(normalized)

    Enum.each(paths, fn parent ->
      prefix = parent <> "/"

      Enum.each(paths, fn child ->
        if child != parent and String.starts_with?(child, prefix) do
          raise ArgumentError,
                "VFS.Memory seed has conflicting paths: #{inspect(parent)} is a file but " <>
                  "#{inspect(child)} places a child under it. A path cannot be both a file " <>
                  "and a directory."
        end
      end)
    end)

    :ok
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
        with {:ok, chunk_size} <- validate_chunk_size(opts),
             {:ok, sliced} <- apply_byte_range(content, opts),
             {:ok, sliced} <- apply_line_range(sliced, opts) do
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

    cond do
      directory?(mem, p) ->
        {:error, Error.new(:eisdir, path: p)}

      ancestor_is_file?(mem, p) ->
        {:error, Error.new(:enotdir, path: p)}

      true ->
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

      ancestor_is_file?(mem, p) ->
        {:error, Error.new(:enotdir, path: p)}

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

  defp ancestor_is_file?(%Memory{tree: tree}, path) do
    path |> ancestors() |> Enum.any?(&Map.has_key?(tree, &1))
  end

  defp ancestors("/"), do: []

  defp ancestors(path) do
    parent = VFS.Path.dirname(path)
    [parent | ancestors(parent)]
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

    # `directory?/2` already covers MapSet membership; the redundant
    # check was kept earlier for "obvious correctness" — removing it
    # to keep the test suite tight (mutation testing flagged the OR).
    if directory?(mem, path), do: mem, else: put_dir(mem, path)
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

  # ── option validation + slicing ──

  defp validate_chunk_size(opts) do
    case Keyword.get(opts, :chunk_size, 64 * 1024) do
      n when is_integer(n) and n > 0 -> {:ok, n}
      _ -> {:error, :einval}
    end
  end

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

  # `last == :end` is always valid — read to EOF.
  defp slice_lines(content, first, :end) do
    lines = String.split(content, "\n")
    sliced = lines |> Enum.slice((first - 1)..(length(lines) - 1)//1) |> Enum.join("\n")
    {:ok, sliced}
  end

  # Integer last must be >= first AND >= 1. Anything else is :einval —
  # specifically `last < first` and `last < 1`. We validate this loudly
  # rather than letting it fall through to `Enum.slice/2`'s range
  # semantics, which interpret negative indices as offsets-from-end and
  # would silently return surprising slices to a caller who passed a
  # malformed range. For LLM agent tools that retrieve precise line
  # context, silent-wrong is the worst possible behavior; loud :einval
  # lets the agent pivot.
  defp slice_lines(content, first, last)
       when is_integer(last) and last >= first and last >= 1 do
    lines = String.split(content, "\n")
    sliced = lines |> Enum.slice((first - 1)..(last - 1)//1) |> Enum.join("\n")
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
