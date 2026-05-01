defmodule VFS do
  @moduledoc """
  Protocol-based virtual filesystem.

  `VFS` is both a *mount table* (a struct holding a list of `{mountpoint, backend}`
  pairs) and the *public API* for working with virtual filesystems. The struct
  itself implements `VFS.Mountable`, so mount tables nest naturally — you can
  mount a `%VFS{}` inside another `%VFS{}` for namespacing.

  Every public op in this module is wrapped in `:telemetry.span/3` so consumers
  can attach OpenTelemetry, log, or metric handlers. See "Telemetry events"
  below for the event taxonomy.

  ## Quick tour

      iex> fs = VFS.new(%{"/repo/README.md" => "hello\\n", "/tmp/scratch" => ""})
      iex> {:ok, "hello\\n", fs} = VFS.read_file(fs, "/repo/README.md")
      iex> {:ok, fs} = VFS.write_file(fs, "/tmp/scratch", "world\\n")
      iex> {:ok, "world\\n", _fs} = VFS.read_file(fs, "/tmp/scratch")
      iex> :ok
      :ok

  ## State threading

  Every op returns the (possibly updated) `%VFS{}` as the last element of its
  success tuple. Threading it forward preserves lazy backend caches. See
  `VFS.Mountable` for the full contract.

  ## Telemetry events

  All under the `[:vfs, _, _]` prefix:

    * `[:vfs, :read_file, :start | :stop | :exception]`
    * `[:vfs, :stream_read, :start | :stop | :exception]`
    * `[:vfs, :write_file, :start | :stop | :exception]`
    * `[:vfs, :walk, :start | :stop]`         (terminal — emitted on enumeration end)
    * `[:vfs, :grep, :start | :stop]`         (terminal)
    * `[:vfs, :glob, :start | :stop]`         (terminal)
    * `[:vfs, :materialize, :start | :stop | :exception]`
    * `[:vfs, :cache, :hit | :miss]`          (emitted by lazy backends themselves)

  Metadata always includes `%{impl: <impl module>}`. See `CLAUDE.md` for the
  complete event taxonomy.
  """

  alias VFS.Mountable
  alias VFS.Path, as: VPath

  @typedoc "A `{mountpoint, backend}` pair. The backend is any `VFS.Mountable`."
  @type mount :: {VPath.t(), Mountable.t()}

  @type t :: %__MODULE__{mounts: [mount]}

  defstruct mounts: []

  # ── construction ──────────────────────────────────────────────────────────

  @doc """
  Build a fresh `%VFS{}`.

  With no arguments, returns an empty mount table. Pass a map to seed an
  in-memory root mount with the given files. Pass `root: backend` to mount
  the given backend at `/`.

  ## Examples

      iex> %VFS{mounts: []} = VFS.new()

      iex> fs = VFS.new(%{"/foo" => "bar"})
      iex> {:ok, "bar", _fs} = VFS.read_file(fs, "/foo")
      iex> :ok
      :ok

      iex> mem = VFS.Memory.new()
      iex> %VFS{mounts: [{"/", _}]} = VFS.new(root: mem)
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec new(%{optional(String.t()) => binary} | [{:root, Mountable.t()}]) :: t()
  def new(initial_files) when is_map(initial_files) do
    mount(%__MODULE__{}, "/", VFS.Memory.new(initial_files))
  end

  def new(root: backend) when is_struct(backend) do
    mount(%__MODULE__{}, "/", backend)
  end

  @doc """
  Mount `backend` at `mountpoint`. If a mount already exists at the same
  point, it is replaced. Mounts are kept sorted by mountpoint length
  (longest first) so longest-prefix routing is a linear scan.

  ## Examples

      iex> fs = VFS.new() |> VFS.mount("/repo", VFS.Memory.new(%{"/x" => "1"}))
      iex> {:ok, "1", _fs} = VFS.read_file(fs, "/repo/x")
      iex> :ok
      :ok
  """
  @spec mount(t(), String.t(), Mountable.t()) :: t()
  def mount(%__MODULE__{} = vfs, mountpoint, backend) when is_struct(backend) do
    mp = VPath.normalize(mountpoint)
    others = Enum.reject(vfs.mounts, fn {p, _} -> p == mp end)
    sorted = [{mp, backend} | others] |> Enum.sort_by(fn {p, _} -> -byte_size(p) end)
    %{vfs | mounts: sorted}
  end

  @doc """
  Remove the mount at `mountpoint`. No-op if no such mount.

  ## Examples

      iex> fs = VFS.new(%{"/a" => "b"}) |> VFS.umount("/")
      iex> %VFS{mounts: []} = fs
  """
  @spec umount(t(), String.t()) :: t()
  def umount(%__MODULE__{} = vfs, mountpoint) do
    mp = VPath.normalize(mountpoint)
    %{vfs | mounts: Enum.reject(vfs.mounts, fn {p, _} -> p == mp end)}
  end

  @doc """
  Return the list of `{mountpoint, backend}` pairs in longest-first order.
  """
  @spec mounts(t()) :: [mount]
  def mounts(%__MODULE__{mounts: ms}), do: ms

  # ── public API helpers (telemetry-wrapped) ────────────────────────────────

  @doc "Read the entire content of `path`."
  @spec read_file(Mountable.t(), String.t()) ::
          {:ok, binary, Mountable.t()} | {:error, Mountable.reason()}
  def read_file(impl, path) do
    span(:read_file, %{path: path, impl: impl_module(impl)}, fn ->
      case Mountable.read_file(impl, path) do
        {:ok, bin, _impl2} = ok -> {ok, %{bytes: byte_size(bin)}, %{}}
        {:error, reason} = err -> {err, %{bytes: 0}, %{error: reason}}
      end
    end)
  end

  @doc "Open `path` for streaming read. See `VFS.Mountable.stream_read/3`."
  @spec stream_read(Mountable.t(), String.t(), keyword) ::
          {:ok, Enumerable.t(), Mountable.t()} | {:error, Mountable.reason()}
  def stream_read(impl, path, opts \\ []) do
    span(:stream_read, %{path: path, impl: impl_module(impl), opts: opts}, fn ->
      case Mountable.stream_read(impl, path, opts) do
        {:ok, _, _} = ok -> {ok, %{}, %{}}
        {:error, reason} = err -> {err, %{}, %{error: reason}}
      end
    end)
  end

  @doc "Write `content` to `path`."
  @spec write_file(Mountable.t(), String.t(), binary, keyword) ::
          {:ok, Mountable.t()} | {:error, Mountable.reason()}
  def write_file(impl, path, content, opts \\ []) when is_binary(content) do
    span(
      :write_file,
      %{path: path, impl: impl_module(impl), bytes: byte_size(content)},
      fn ->
        case Mountable.write_file(impl, path, content, opts) do
          {:ok, _} = ok -> {ok, %{}, %{}}
          {:error, reason} = err -> {err, %{}, %{error: reason}}
        end
      end
    )
  end

  @doc "Append `content` to `path`."
  @spec append_file(Mountable.t(), String.t(), binary) ::
          {:ok, Mountable.t()} | {:error, Mountable.reason()}
  def append_file(impl, path, content) when is_binary(content) do
    span(
      :append_file,
      %{path: path, impl: impl_module(impl), bytes: byte_size(content)},
      fn ->
        case Mountable.append_file(impl, path, content) do
          {:ok, _} = ok -> {ok, %{}, %{}}
          {:error, reason} = err -> {err, %{}, %{error: reason}}
        end
      end
    )
  end

  @doc "Create directory at `path`."
  @spec mkdir(Mountable.t(), String.t(), keyword) ::
          {:ok, Mountable.t()} | {:error, Mountable.reason()}
  def mkdir(impl, path, opts \\ []) do
    span(:mkdir, %{path: path, impl: impl_module(impl), opts: opts}, fn ->
      case Mountable.mkdir(impl, path, opts) do
        {:ok, _} = ok -> {ok, %{}, %{}}
        {:error, reason} = err -> {err, %{}, %{error: reason}}
      end
    end)
  end

  @doc "Remove `path`."
  @spec rm(Mountable.t(), String.t(), keyword) ::
          {:ok, Mountable.t()} | {:error, Mountable.reason()}
  def rm(impl, path, opts \\ []) do
    span(:rm, %{path: path, impl: impl_module(impl), opts: opts}, fn ->
      case Mountable.rm(impl, path, opts) do
        {:ok, _} = ok -> {ok, %{}, %{}}
        {:error, reason} = err -> {err, %{}, %{error: reason}}
      end
    end)
  end

  @doc "Set permission bits on `path`."
  @spec chmod(Mountable.t(), String.t(), non_neg_integer) ::
          {:ok, Mountable.t()} | {:error, Mountable.reason()}
  def chmod(impl, path, mode) do
    span(:chmod, %{path: path, impl: impl_module(impl), mode: mode}, fn ->
      case Mountable.chmod(impl, path, mode) do
        {:ok, _} = ok -> {ok, %{}, %{}}
        {:error, reason} = err -> {err, %{}, %{error: reason}}
      end
    end)
  end

  @doc "Whether `path` exists."
  @spec exists?(Mountable.t(), String.t()) :: {boolean, Mountable.t()}
  def exists?(impl, path), do: Mountable.exists?(impl, path)

  @doc "Stat `path`."
  @spec stat(Mountable.t(), String.t()) ::
          {:ok, VFS.Stat.t(), Mountable.t()} | {:error, Mountable.reason()}
  def stat(impl, path), do: Mountable.stat(impl, path)

  @doc "List entries directly under directory `path`."
  @spec readdir(Mountable.t(), String.t()) ::
          {:ok, [String.t()], Mountable.t()} | {:error, Mountable.reason()}
  def readdir(impl, path), do: Mountable.readdir(impl, path)

  @doc "Pre-warm any internal cache. See `VFS.Mountable.materialize/2`."
  @spec materialize(Mountable.t(), keyword) ::
          {:ok, Mountable.t()} | {:error, Mountable.reason()}
  def materialize(impl, opts \\ []) do
    span(:materialize, %{impl: impl_module(impl)}, fn ->
      case Mountable.materialize(impl, opts) do
        {:ok, _} = ok -> {ok, %{}, %{}}
        {:error, reason} = err -> {err, %{}, %{error: reason}}
      end
    end)
  end

  @doc "Capabilities supported by the impl."
  @spec capabilities(Mountable.t()) :: MapSet.t(Mountable.capability())
  def capabilities(impl), do: Mountable.capabilities(impl)

  @doc """
  Raise a helpful error if `value` does not implement `VFS.Mountable`.

  Useful at trust boundaries (constructor arguments, public API entry
  points) where catching a missing `defimpl` early beats a
  `Protocol.UndefinedError` deep in a downstream call.

  ## Examples

      iex> VFS.assert_implemented!(VFS.Memory.new())
      :ok

      iex> VFS.assert_implemented!(%URI{})
      ** (ArgumentError) %URI{} does not implement the VFS.Mountable protocol. Add `defimpl VFS.Mountable, for: URI do ... end` or pass a struct that has one.
  """
  @spec assert_implemented!(term) :: :ok
  def assert_implemented!(value) do
    if Mountable.impl_for(value) == nil do
      raise ArgumentError,
            "#{inspect_struct(value)} does not implement the VFS.Mountable protocol. " <>
              "Add `defimpl VFS.Mountable, for: #{module_name(value)} do ... end` " <>
              "or pass a struct that has one."
    end

    :ok
  end

  defp inspect_struct(%mod{}), do: "%#{inspect(mod)}{}"
  defp inspect_struct(other), do: inspect(other)

  defp module_name(%mod{}), do: inspect(mod)
  defp module_name(_), do: "<term>"

  @doc """
  Lazily walk the tree under `root`. Emits `{path, %VFS.Stat{}}` tuples.
  Telemetry: `[:vfs, :walk, :start | :stop]` (terminal — emitted on
  enumeration completion).

  ## Examples

      iex> fs = VFS.new(%{"/a" => "1", "/b/c" => "2"})
      iex> fs |> VFS.walk("/", []) |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      ["/a", "/b/c"]
  """
  @spec walk(Mountable.t(), String.t(), keyword) :: Enumerable.t()
  def walk(impl, root, opts \\ []) do
    meta = %{root: root, impl: impl_module(impl), opts: opts}
    inner = Mountable.walk(impl, root, opts)
    instrument_terminal(inner, [:vfs, :walk], meta, :entries)
  end

  @doc """
  Recursive grep across the tree under `root`. Returns a `Stream` of
  `{path, line_number, line}` tuples.

  Memory bounded to one file's content at a time.

  ## Examples

      iex> fs = VFS.new(%{"/a.ex" => "todo: x\\nok\\nTODO y\\n"})
      iex> fs |> VFS.grep("/", ~r/TODO/i) |> Enum.to_list()
      [{"/a.ex", 1, "todo: x"}, {"/a.ex", 3, "TODO y"}]
  """
  @spec grep(Mountable.t(), String.t(), Regex.t(), keyword) :: Enumerable.t()
  def grep(impl, root, %Regex{} = pattern, opts \\ []) do
    meta = %{root: root, impl: impl_module(impl), pattern: pattern}

    inner =
      impl
      |> Mountable.walk(root, opts)
      |> Stream.filter(fn {_, %VFS.Stat{type: t}} -> t == :regular end)
      |> Stream.flat_map(fn {path, _stat} ->
        case Mountable.stream_read(impl, path, []) do
          {:ok, byte_stream, _} -> scan_lines(byte_stream, pattern, path)
          {:error, _} -> []
        end
      end)

    instrument_terminal(inner, [:vfs, :grep], meta, :matches)
  end

  @doc """
  Glob match. `*` matches any chars within a segment; `**` matches any
  chars including `/`; `?` matches a single char within a segment.
  Returns a `Stream` of matched paths.

  ## Examples

      iex> fs = VFS.new(%{"/a.ex" => "", "/b.exs" => "", "/sub/c.ex" => ""})
      iex> fs |> VFS.glob("/", "**/*.ex") |> Enum.sort()
      ["/a.ex", "/sub/c.ex"]
  """
  @spec glob(Mountable.t(), String.t(), String.t(), keyword) :: Enumerable.t()
  def glob(impl, root, pattern, opts \\ []) when is_binary(pattern) do
    meta = %{root: root, impl: impl_module(impl), pattern: pattern}
    re = glob_to_regex(pattern)

    inner =
      impl
      |> Mountable.walk(root, opts)
      |> Stream.filter(fn {_, %VFS.Stat{type: t}} -> t == :regular end)
      |> Stream.flat_map(fn {path, _stat} ->
        rel = relative_to_root(path, root)
        if Regex.match?(re, rel), do: [path], else: []
      end)

    instrument_terminal(inner, [:vfs, :glob], meta, :matches)
  end

  # ── composed ops not in the protocol ──────────────────────────────────────

  @doc """
  Copy `src` to `dest`. Reads the full file then writes it; not atomic.
  Returns the impl with both reads and writes threaded through.
  """
  @spec cp(Mountable.t(), String.t(), String.t()) ::
          {:ok, Mountable.t()} | {:error, Mountable.reason()}
  def cp(impl, src, dest) do
    case read_file(impl, src) do
      {:ok, content, impl2} -> write_file(impl2, dest, content)
      {:error, _} = err -> err
    end
  end

  @doc """
  Move `src` to `dest`. Equivalent to `cp` then `rm` for v1.

  Cross-mount moves return `{:error, :exdev}` when both endpoints route to
  different leaf backends within the same mount table — the caller is
  expected to do a copy-then-delete in that case.
  """
  @spec mv(t(), String.t(), String.t()) :: {:ok, t()} | {:error, Mountable.reason()}
  def mv(%__MODULE__{} = vfs, src, dest) do
    src_n = VPath.normalize(src)
    dest_n = VPath.normalize(dest)

    if different_mounts?(vfs, src_n, dest_n) do
      {:error, :exdev}
    else
      with {:ok, content, vfs2} <- read_file(vfs, src_n),
           {:ok, vfs3} <- write_file(vfs2, dest_n, content) do
        rm(vfs3, src_n, [])
      end
    end
  end

  # ── internal: mount routing ───────────────────────────────────────────────

  @doc false
  def __resolve__(%__MODULE__{mounts: mounts}, path) do
    Enum.find_value(mounts, :no_mount, fn {mp, backend} ->
      case VPath.relative_to(path, mp) do
        {:ok, sub} -> {:ok, mp, sub, backend}
        :error -> nil
      end
    end)
  end

  @doc false
  def __put_mount__(%__MODULE__{mounts: mounts} = vfs, mp, new_backend) do
    %{vfs | mounts: Enum.map(mounts, &if(elem(&1, 0) == mp, do: {mp, new_backend}, else: &1))}
  end

  @doc false
  def __synthetic_dir__(%__MODULE__{mounts: mounts}, path) do
    prefix = if path == "/", do: "/", else: path <> "/"
    Enum.any?(mounts, fn {mp, _} -> mp != path and String.starts_with?(mp, prefix) end)
  end

  @doc false
  def __synthetic_children__(%__MODULE__{mounts: mounts}, path) do
    prefix = if path == "/", do: "/", else: path <> "/"

    Enum.flat_map(mounts, fn {mp, _} ->
      if mp != path and String.starts_with?(mp, prefix) do
        rest = String.replace_prefix(mp, prefix, "")
        [rest |> String.split("/", parts: 2) |> hd()]
      else
        []
      end
    end)
  end

  defp different_mounts?(%__MODULE__{} = vfs, src, dest) do
    case {__resolve__(vfs, src), __resolve__(vfs, dest)} do
      {{:ok, mp1, _, _}, {:ok, mp2, _, _}} -> mp1 != mp2
      _ -> false
    end
  end

  # ── telemetry helpers ─────────────────────────────────────────────────────

  defp impl_module(impl) when is_struct(impl), do: impl.__struct__

  defp span(op, start_meta, fun) do
    :telemetry.span([:vfs, op], start_meta, fn ->
      {result, extras, stop_meta} = fun.()
      {result, extras, Map.merge(start_meta, stop_meta)}
    end)
  end

  defp instrument_terminal(inner, event_prefix, meta, count_key) do
    Stream.transform(
      inner,
      fn ->
        :telemetry.execute(
          event_prefix ++ [:start],
          %{system_time: System.system_time()},
          meta
        )

        {0, System.monotonic_time()}
      end,
      fn item, {count, start_time} -> {[item], {count + 1, start_time}} end,
      fn {count, start_time} ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          event_prefix ++ [:stop],
          Map.put(%{duration: duration}, count_key, count),
          meta
        )
      end
    )
  end

  # ── grep / glob plumbing ──────────────────────────────────────────────────

  defp scan_lines(byte_stream, pattern, path) do
    content = byte_stream |> Enum.to_list() |> IO.iodata_to_binary()

    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, n} ->
      if Regex.match?(pattern, line), do: [{path, n, line}], else: []
    end)
  end

  defp glob_to_regex(pattern) do
    pattern
    |> Regex.escape()
    |> String.replace("\\*\\*", ".*")
    |> String.replace("\\*", "[^/]*")
    |> String.replace("\\?", "[^/]")
    |> then(&Regex.compile!("^/?" <> &1 <> "$"))
  end

  defp relative_to_root(path, "/"), do: path

  defp relative_to_root(path, root) do
    {:ok, rel} = VPath.relative_to(path, root)
    rel
  end
end

defimpl VFS.Mountable, for: VFS do
  use VFS.Skeleton

  alias VFS.Stat

  @epoch DateTime.from_unix!(0)

  def exists?(%VFS{} = vfs, path) do
    p = VFS.Path.normalize(path)

    case VFS.__resolve__(vfs, p) do
      {:ok, mp, sub, backend} ->
        case VFS.Mountable.exists?(backend, sub) do
          {true, new_backend} ->
            {true, VFS.__put_mount__(vfs, mp, new_backend)}

          {false, new_backend} ->
            {VFS.__synthetic_dir__(vfs, p), VFS.__put_mount__(vfs, mp, new_backend)}
        end

      :no_mount ->
        {VFS.__synthetic_dir__(vfs, p), vfs}
    end
  end

  def stat(%VFS{} = vfs, path) do
    p = VFS.Path.normalize(path)

    case VFS.__resolve__(vfs, p) do
      {:ok, mp, sub, backend} ->
        case VFS.Mountable.stat(backend, sub) do
          {:ok, stat, new_backend} ->
            {:ok, stat, VFS.__put_mount__(vfs, mp, new_backend)}

          {:error, :enoent} ->
            if VFS.__synthetic_dir__(vfs, p) do
              {:ok, synthetic_dir_stat(), vfs}
            else
              {:error, :enoent}
            end

          {:error, _} = err ->
            err
        end

      :no_mount ->
        if VFS.__synthetic_dir__(vfs, p) do
          {:ok, synthetic_dir_stat(), vfs}
        else
          {:error, :enoent}
        end
    end
  end

  def lstat(vfs, path), do: stat(vfs, path)

  def readdir(%VFS{} = vfs, path) do
    p = VFS.Path.normalize(path)
    synthetic = VFS.__synthetic_children__(vfs, p)

    case VFS.__resolve__(vfs, p) do
      {:ok, mp, sub, backend} ->
        case VFS.Mountable.readdir(backend, sub) do
          {:ok, names, new_backend} ->
            {:ok, merge_sorted(names, synthetic), VFS.__put_mount__(vfs, mp, new_backend)}

          {:error, :enoent} when synthetic != [] ->
            {:ok, Enum.sort(synthetic), vfs}

          {:error, _} = err ->
            err
        end

      :no_mount ->
        if synthetic == [], do: {:error, :enoent}, else: {:ok, Enum.sort(synthetic), vfs}
    end
  end

  def readlink(%VFS{} = vfs, path) do
    delegate_resolve(vfs, path, :readlink, [])
  end

  def stream_read(%VFS{} = vfs, path, opts) do
    delegate_resolve(vfs, path, :stream_read, [opts])
  end

  def read_file(%VFS{} = vfs, path) do
    delegate_resolve(vfs, path, :read_file, [])
  end

  def walk(%VFS{} = vfs, root, opts) do
    p = VFS.Path.normalize(root)

    inner_streams =
      Enum.flat_map(vfs.mounts, fn {mp, backend} ->
        case relate_mount(p, mp) do
          :include -> [walk_and_prefix(backend, "/", mp, opts)]
          {:descend, sub} -> [walk_and_prefix(backend, sub, mp, opts)]
          :unrelated -> []
        end
      end)

    Stream.concat(inner_streams)
  end

  def materialize(%VFS{} = vfs, opts) do
    Enum.reduce_while(vfs.mounts, {:ok, vfs}, fn {mp, backend}, {:ok, acc} ->
      case VFS.Mountable.materialize(backend, opts) do
        {:ok, new_backend} -> {:cont, {:ok, VFS.__put_mount__(acc, mp, new_backend)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  def write_file(%VFS{} = vfs, path, content, opts) do
    delegate_mutation(vfs, path, :write_file, [content, opts])
  end

  def append_file(%VFS{} = vfs, path, content) do
    delegate_mutation(vfs, path, :append_file, [content])
  end

  def mkdir(%VFS{} = vfs, path, opts) do
    delegate_mutation(vfs, path, :mkdir, [opts])
  end

  def rm(%VFS{} = vfs, path, opts) do
    delegate_mutation(vfs, path, :rm, [opts])
  end

  def chmod(%VFS{} = vfs, path, mode) do
    delegate_mutation(vfs, path, :chmod, [mode])
  end

  def symlink(%VFS{} = vfs, target, link_path) do
    p = VFS.Path.normalize(link_path)

    case VFS.__resolve__(vfs, p) do
      {:ok, mp, sub, backend} ->
        case VFS.Mountable.symlink(backend, target, sub) do
          {:ok, new_backend} -> {:ok, VFS.__put_mount__(vfs, mp, new_backend)}
          {:error, _} = err -> err
        end

      :no_mount ->
        {:error, :enoent}
    end
  end

  def link(%VFS{} = vfs, existing, new) do
    e = VFS.Path.normalize(existing)
    n = VFS.Path.normalize(new)

    case {VFS.__resolve__(vfs, e), VFS.__resolve__(vfs, n)} do
      {{:ok, mp1, sub_e, _}, {:ok, mp2, sub_n, backend}} when mp1 == mp2 ->
        case VFS.Mountable.link(backend, sub_e, sub_n) do
          {:ok, new_backend} -> {:ok, VFS.__put_mount__(vfs, mp2, new_backend)}
          {:error, _} = err -> err
        end

      {{:ok, _, _, _}, {:ok, _, _, _}} ->
        {:error, :exdev}

      _ ->
        {:error, :enoent}
    end
  end

  def capabilities(%VFS{mounts: []}), do: MapSet.new()

  def capabilities(%VFS{mounts: mounts}) do
    mounts
    |> Enum.map(fn {_, backend} -> VFS.Mountable.capabilities(backend) end)
    |> Enum.reduce(&MapSet.intersection/2)
  end

  # ── helpers ──

  defp synthetic_dir_stat do
    %Stat{type: :directory, size: 0, mtime: @epoch}
  end

  defp merge_sorted(real, synthetic) do
    (real ++ synthetic) |> Enum.uniq() |> Enum.sort()
  end

  defp strip_leading("/" <> rest), do: rest

  defp ensure_trailing_slash("/"), do: "/"
  defp ensure_trailing_slash(p), do: p <> "/"

  defp walk_and_prefix(backend, sub, mp, opts) do
    backend
    |> VFS.Mountable.walk(sub, opts)
    |> Stream.map(fn {sub_path, stat} ->
      {VFS.Path.join(mp, strip_leading(sub_path)), stat}
    end)
  end

  defp relate_mount(root, mp) do
    cond do
      root == mp -> :include
      String.starts_with?(mp, ensure_trailing_slash(root)) -> :include
      String.starts_with?(root, ensure_trailing_slash(mp)) -> descend(root, mp)
      true -> :unrelated
    end
  end

  defp descend(root, mp) do
    {:ok, sub} = VFS.Path.relative_to(root, mp)
    {:descend, sub}
  end

  defp delegate_resolve(%VFS{} = vfs, path, op, extra_args) do
    p = VFS.Path.normalize(path)

    case VFS.__resolve__(vfs, p) do
      {:ok, mp, sub, backend} ->
        case apply(VFS.Mountable, op, [backend, sub | extra_args]) do
          {:ok, payload, new_backend} ->
            {:ok, payload, VFS.__put_mount__(vfs, mp, new_backend)}

          {:error, _} = err ->
            err
        end

      :no_mount ->
        {:error, :enoent}
    end
  end

  defp delegate_mutation(%VFS{} = vfs, path, op, extra_args) do
    p = VFS.Path.normalize(path)

    case VFS.__resolve__(vfs, p) do
      {:ok, mp, sub, backend} ->
        case apply(VFS.Mountable, op, [backend, sub | extra_args]) do
          {:ok, new_backend} -> {:ok, VFS.__put_mount__(vfs, mp, new_backend)}
          {:error, _} = err -> err
        end

      :no_mount ->
        {:error, :enoent}
    end
  end
end
