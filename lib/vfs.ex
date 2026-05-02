defmodule VFS do
  @moduledoc """
  Protocol-based virtual filesystem.

  `VFS` is both a *mount table* (a struct holding a list of
  `{mountpoint, backend}` pairs) and the *public API* for working with
  virtual filesystems. The struct itself implements `VFS.Mountable`, so
  mount tables nest naturally — you can mount a `%VFS{}` inside another
  `%VFS{}` for namespacing.

  Every public op in this module is wrapped in `:telemetry.span/3` so
  consumers can attach OpenTelemetry, log, or metric handlers. See
  "Telemetry events" below.

  ## Quick tour

      iex> fs = VFS.new() |> VFS.mount("/", VFS.Memory.new(%{"/repo/README.md" => "hello\\n", "/tmp/scratch" => ""}))
      iex> {:ok, "hello\\n", fs} = VFS.read_file(fs, "/repo/README.md")
      iex> {:ok, fs} = VFS.write_file(fs, "/tmp/scratch", "world\\n")
      iex> {:ok, "world\\n", _fs} = VFS.read_file(fs, "/tmp/scratch")
      iex> :ok
      :ok

  ## State threading

  Every op returns the (possibly updated) `%VFS{}` as the last element of
  its success tuple. Threading it forward preserves lazy backend caches.
  See `VFS.Mountable` for the full contract.

  ## Telemetry events

  All under the `[:vfs, _, _]` prefix:

    * `[:vfs, :read_file, :start | :stop | :exception]`
    * `[:vfs, :stream_read, :start | :stop | :exception]`
    * `[:vfs, :write_file, :start | :stop | :exception]`
    * `[:vfs, :mkdir, :start | :stop | :exception]`
    * `[:vfs, :rm, :start | :stop | :exception]`
    * `[:vfs, :walk, :start | :stop]`         (terminal — emitted on enumeration end)
    * `[:vfs, :materialize, :start | :stop | :exception]`
    * `[:vfs, :cache, :hit | :miss]`          (emitted by lazy backends themselves)

  Metadata always includes `%{impl: <impl module>}`. Errors land in the
  `:stop` event metadata as `%{error: %VFS.Error{...}}`.
  """

  alias VFS.Error
  alias VFS.Mountable
  alias VFS.Path, as: VPath

  @typedoc "A `{mountpoint, backend}` pair. The backend is any `VFS.Mountable`."
  @type mount :: {VPath.t(), Mountable.t()}

  @type t :: %__MODULE__{mounts: [mount]}

  defstruct mounts: []

  # ── construction ──────────────────────────────────────────────────────────

  @doc """
  Build an empty mount table. Use `mount/3` to attach backends.

  ## Examples

      iex> %VFS{mounts: []} = VFS.new()

      iex> fs = VFS.new() |> VFS.mount("/", VFS.Memory.new(%{"/foo" => "bar"}))
      iex> {:ok, "bar", _fs} = VFS.read_file(fs, "/foo")
      iex> :ok
      :ok
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

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

      iex> fs = VFS.new() |> VFS.mount("/", VFS.Memory.new(%{"/a" => "b"})) |> VFS.umount("/")
      iex> %VFS{mounts: []} = fs
  """
  @spec umount(t(), String.t()) :: t()
  def umount(%__MODULE__{} = vfs, mountpoint) do
    mp = VPath.normalize(mountpoint)
    %{vfs | mounts: Enum.reject(vfs.mounts, fn {p, _} -> p == mp end)}
  end

  @doc "Return the list of `{mountpoint, backend}` pairs in longest-first order."
  @spec mounts(t()) :: [mount]
  def mounts(%__MODULE__{mounts: ms}), do: ms

  # ── public API helpers (telemetry-wrapped) ────────────────────────────────

  @doc """
  Read the entire content of `path`.

  Derived from `stream_read/3` — runs the chunk stream into a binary.
  """
  @spec read_file(Mountable.t(), String.t()) ::
          {:ok, binary, Mountable.t()} | {:error, Error.t()}
  def read_file(impl, path) do
    span(:read_file, %{path: path, impl: impl_module(impl)}, fn ->
      case Mountable.stream_read(impl, path, []) do
        {:ok, stream, impl2} ->
          bin = stream |> Enum.to_list() |> IO.iodata_to_binary()
          {{:ok, bin, impl2}, %{bytes: byte_size(bin)}, %{}}

        {:error, %Error{} = err} ->
          {{:error, err}, %{bytes: 0}, %{error: err}}
      end
    end)
  end

  @doc "Open `path` for streaming read. See `VFS.Mountable.stream_read/3`."
  @spec stream_read(Mountable.t(), String.t(), keyword) ::
          {:ok, Enumerable.t(binary), Mountable.t()} | {:error, Error.t()}
  def stream_read(impl, path, opts \\ []) do
    span(:stream_read, %{path: path, impl: impl_module(impl), opts: opts}, fn ->
      case Mountable.stream_read(impl, path, opts) do
        {:ok, _, _} = ok -> {ok, %{}, %{}}
        {:error, %Error{} = err} -> {{:error, err}, %{}, %{error: err}}
      end
    end)
  end

  @doc "Write `content` to `path`."
  @spec write_file(Mountable.t(), String.t(), binary, keyword) ::
          {:ok, Mountable.t()} | {:error, Error.t()}
  def write_file(impl, path, content, opts \\ []) when is_binary(content) do
    span(
      :write_file,
      %{path: path, impl: impl_module(impl), bytes: byte_size(content)},
      fn ->
        case Mountable.write_file(impl, path, content, opts) do
          {:ok, _} = ok -> {ok, %{}, %{}}
          {:error, %Error{} = err} -> {{:error, err}, %{}, %{error: err}}
        end
      end
    )
  end

  @doc "Create directory at `path`."
  @spec mkdir(Mountable.t(), String.t(), keyword) ::
          {:ok, Mountable.t()} | {:error, Error.t()}
  def mkdir(impl, path, opts \\ []) do
    span(:mkdir, %{path: path, impl: impl_module(impl), opts: opts}, fn ->
      case Mountable.mkdir(impl, path, opts) do
        {:ok, _} = ok -> {ok, %{}, %{}}
        {:error, %Error{} = err} -> {{:error, err}, %{}, %{error: err}}
      end
    end)
  end

  @doc "Remove `path`."
  @spec rm(Mountable.t(), String.t(), keyword) ::
          {:ok, Mountable.t()} | {:error, Error.t()}
  def rm(impl, path, opts \\ []) do
    span(:rm, %{path: path, impl: impl_module(impl), opts: opts}, fn ->
      case Mountable.rm(impl, path, opts) do
        {:ok, _} = ok -> {ok, %{}, %{}}
        {:error, %Error{} = err} -> {{:error, err}, %{}, %{error: err}}
      end
    end)
  end

  @doc "Whether `path` exists."
  @spec exists?(Mountable.t(), String.t()) :: {boolean, Mountable.t()}
  def exists?(impl, path), do: Mountable.exists?(impl, path)

  @doc "Stat `path`."
  @spec stat(Mountable.t(), String.t()) ::
          {:ok, VFS.Stat.t(), Mountable.t()} | {:error, Error.t()}
  def stat(impl, path), do: Mountable.stat(impl, path)

  @doc "List entries directly under directory `path`."
  @spec readdir(Mountable.t(), String.t()) ::
          {:ok, [String.t()], Mountable.t()} | {:error, Error.t()}
  def readdir(impl, path), do: Mountable.readdir(impl, path)

  @doc "Pre-warm any internal cache. See `VFS.Mountable.materialize/2`."
  @spec materialize(Mountable.t(), keyword) ::
          {:ok, Mountable.t()} | {:error, Error.t()}
  def materialize(impl, opts \\ []) do
    span(:materialize, %{impl: impl_module(impl)}, fn ->
      case Mountable.materialize(impl, opts) do
        {:ok, _} = ok -> {ok, %{}, %{}}
        {:error, %Error{} = err} -> {{:error, err}, %{}, %{error: err}}
      end
    end)
  end

  @doc "Capabilities supported by the impl."
  @spec capabilities(Mountable.t()) :: MapSet.t(Mountable.capability())
  def capabilities(impl), do: Mountable.capabilities(impl)

  @doc """
  Lazily walk the tree under `root`. Emits `{path, %VFS.Stat{}}` tuples.
  Telemetry: `[:vfs, :walk, :start | :stop]` (terminal — emitted on
  enumeration completion).

  ## Examples

      iex> fs = VFS.new() |> VFS.mount("/", VFS.Memory.new(%{"/a" => "1", "/b/c" => "2"}))
      iex> fs |> VFS.walk("/", []) |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      ["/a", "/b/c"]
  """
  @spec walk(Mountable.t(), String.t(), keyword) :: Enumerable.t({String.t(), VFS.Stat.t()})
  def walk(impl, root, opts \\ []) do
    meta = %{root: root, impl: impl_module(impl), opts: opts}
    inner = Mountable.walk(impl, root, opts)
    instrument_terminal(inner, [:vfs, :walk], meta, :entries)
  end

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
        # event_prefix is always 2 atoms; ++ cost is constant.
        # vfs:audit-ok
        start_event = event_prefix ++ [:start]
        :telemetry.execute(start_event, %{system_time: System.system_time()}, meta)

        {0, System.monotonic_time()}
      end,
      fn item, {count, start_time} -> {[item], {count + 1, start_time}} end,
      fn {count, start_time} ->
        duration = System.monotonic_time() - start_time

        # vfs:audit-ok — 2 atoms
        stop_event = event_prefix ++ [:stop]

        :telemetry.execute(
          stop_event,
          Map.put(%{duration: duration}, count_key, count),
          meta
        )
      end
    )
  end

  # ── helpers used by the defimpl below ────────────────────────────────────

  @doc false
  def __strip_leading__("/" <> rest), do: rest

  @doc false
  def __ensure_trailing_slash__("/"), do: "/"
  def __ensure_trailing_slash__(p), do: p <> "/"

  @doc false
  def __relate_mount__(root, mp) do
    cond do
      root == mp -> :include
      String.starts_with?(mp, __ensure_trailing_slash__(root)) -> :include
      String.starts_with?(root, __ensure_trailing_slash__(mp)) -> __descend__(root, mp)
      true -> :unrelated
    end
  end

  defp __descend__(root, mp) do
    {:ok, sub} = VPath.relative_to(root, mp)
    {:descend, sub}
  end
end

defimpl VFS.Mountable, for: VFS do
  use VFS.Skeleton

  alias VFS.Error
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

          {:error, %Error{kind: :enoent}} ->
            if VFS.__synthetic_dir__(vfs, p) do
              {:ok, synthetic_dir_stat(), vfs}
            else
              {:error, Error.new(:enoent, path: p, mount: mp)}
            end

          {:error, %Error{} = err} ->
            {:error, Error.put_mount(%{err | path: p}, mp)}
        end

      :no_mount ->
        if VFS.__synthetic_dir__(vfs, p) do
          {:ok, synthetic_dir_stat(), vfs}
        else
          {:error, Error.new(:enoent, path: p)}
        end
    end
  end

  def readdir(%VFS{} = vfs, path) do
    p = VFS.Path.normalize(path)
    synthetic = VFS.__synthetic_children__(vfs, p)

    case VFS.__resolve__(vfs, p) do
      {:ok, mp, sub, backend} ->
        case VFS.Mountable.readdir(backend, sub) do
          {:ok, names, new_backend} ->
            {:ok, merge_entries(names, synthetic), VFS.__put_mount__(vfs, mp, new_backend)}

          {:error, %Error{kind: :enoent}} when synthetic != [] ->
            {:ok, Enum.sort(synthetic), vfs}

          {:error, %Error{} = err} ->
            {:error, Error.put_mount(%{err | path: p}, mp)}
        end

      :no_mount ->
        if synthetic == [],
          do: {:error, Error.new(:enoent, path: p)},
          else: {:ok, Enum.sort(synthetic), vfs}
    end
  end

  def stream_read(%VFS{} = vfs, path, opts) do
    delegate_resolve(vfs, path, :stream_read, [opts])
  end

  def walk(%VFS{} = vfs, root, opts) do
    p = VFS.Path.normalize(root)

    inner_streams =
      Enum.flat_map(vfs.mounts, fn {mp, backend} ->
        case VFS.__relate_mount__(p, mp) do
          :include -> [walk_and_prefix(vfs, backend, "/", mp, opts)]
          {:descend, sub} -> [walk_and_prefix(vfs, backend, sub, mp, opts)]
          :unrelated -> []
        end
      end)

    Stream.concat(inner_streams)
  end

  def materialize(%VFS{} = vfs, opts) do
    Enum.reduce_while(vfs.mounts, {:ok, vfs}, fn {mp, backend}, {:ok, acc} ->
      case VFS.Mountable.materialize(backend, opts) do
        {:ok, new_backend} ->
          {:cont, {:ok, VFS.__put_mount__(acc, mp, new_backend)}}

        {:error, %Error{} = err} ->
          {:halt, {:error, Error.put_mount(err, mp)}}
      end
    end)
  end

  def write_file(%VFS{} = vfs, path, content, opts) do
    delegate_mutation(vfs, path, :write_file, [content, opts])
  end

  def mkdir(%VFS{} = vfs, path, opts) do
    delegate_mutation(vfs, path, :mkdir, [opts])
  end

  def rm(%VFS{} = vfs, path, opts) do
    delegate_mutation(vfs, path, :rm, [opts])
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

  # When the backend's listing is a bounded list, merge with synthetic
  # children, dedup, and sort — matches the bounded-readdir convention.
  # When it's a Stream (paginated, unbounded), prepend synthetic children
  # then concat the stream — preserves laziness so consumers can `Stream.take`.
  defp merge_entries(real, synthetic) when is_list(real) do
    # synthetic is the small list (mountpoint names); ++ stays cheap.
    # vfs:audit-ok
    (synthetic ++ real) |> Enum.uniq() |> Enum.sort()
  end

  defp merge_entries(real, synthetic) do
    Stream.concat(Enum.sort(synthetic), real)
  end

  # Walk a single mount and prefix its emissions with the mountpoint,
  # then drop any emission that the mount-table's longest-prefix routing
  # would route to a *different* mount. This is the shadowing filter:
  # if `/` is mounted with `/a/old` and `/a` is mounted separately,
  # `/a/old` is emitted by the root mount but unreachable via point
  # lookup (read_file routes to the `/a` mount, which doesn't have
  # "old"). Walk must respect that — the namespace seen by walk has to
  # equal the namespace seen by read_file.
  defp walk_and_prefix(vfs, backend, sub, mp, opts) do
    backend
    |> VFS.Mountable.walk(sub, opts)
    |> Stream.flat_map(fn {sub_path, stat} ->
      full = VFS.Path.join(mp, VFS.__strip_leading__(sub_path))

      case VFS.__resolve__(vfs, full) do
        {:ok, ^mp, _resolved_sub, _backend} -> [{full, stat}]
        # Resolves to a different mount → shadowed; drop.
        # Resolves to :no_mount can't happen here since `mp` covers it.
        _ -> []
      end
    end)
  end

  defp delegate_resolve(%VFS{} = vfs, path, op, extra_args) do
    p = VFS.Path.normalize(path)

    case VFS.__resolve__(vfs, p) do
      {:ok, mp, sub, backend} ->
        case apply(VFS.Mountable, op, [backend, sub | extra_args]) do
          {:ok, payload, new_backend} ->
            {:ok, payload, VFS.__put_mount__(vfs, mp, new_backend)}

          {:error, %Error{} = err} ->
            {:error, Error.put_mount(%{err | path: p}, mp)}
        end

      :no_mount ->
        {:error, Error.new(:enoent, path: p)}
    end
  end

  defp delegate_mutation(%VFS{} = vfs, path, op, extra_args) do
    p = VFS.Path.normalize(path)

    case VFS.__resolve__(vfs, p) do
      {:ok, mp, sub, backend} ->
        case apply(VFS.Mountable, op, [backend, sub | extra_args]) do
          {:ok, new_backend} ->
            {:ok, VFS.__put_mount__(vfs, mp, new_backend)}

          {:error, %Error{} = err} ->
            {:error, Error.put_mount(%{err | path: p}, mp)}
        end

      :no_mount ->
        {:error, Error.new(:enoent, path: p)}
    end
  end
end
