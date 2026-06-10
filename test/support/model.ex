defmodule VFS.Test.Model do
  @moduledoc false
  # Reference model for stateful property testing. Mirrors the semantics
  # of `VFS.Memory` using plain data structures, so that any divergence
  # between the impl and the model under a random op sequence is a real
  # bug in the impl.
  #
  # Tracks files (path -> content) and explicit dirs (MapSet). A path is
  # a "directory" iff it's the root, an explicit dir, or has at least
  # one descendant in either map.

  @type t :: %__MODULE__{
          files: %{VFS.Path.t() => binary},
          dirs: MapSet.t(VFS.Path.t())
        }

  defstruct files: %{}, dirs: MapSet.new()

  @spec new() :: t()
  def new, do: %__MODULE__{}

  # ── observations ────────────────────────────────────────────────────────

  @spec read(t(), String.t()) :: {:ok, binary} | {:error, atom}
  def read(%__MODULE__{} = m, path) do
    p = VFS.Path.normalize(path)

    case Map.fetch(m.files, p) do
      {:ok, content} ->
        {:ok, content}

      :error ->
        if directory?(m, p), do: {:error, :eisdir}, else: {:error, :enoent}
    end
  end

  @spec exists?(t(), String.t()) :: boolean
  def exists?(%__MODULE__{} = m, path) do
    p = VFS.Path.normalize(path)
    Map.has_key?(m.files, p) or directory?(m, p)
  end

  @spec stat_type(t(), String.t()) :: {:ok, :regular | :directory} | {:error, :enoent}
  def stat_type(%__MODULE__{} = m, path) do
    p = VFS.Path.normalize(path)

    cond do
      Map.has_key?(m.files, p) -> {:ok, :regular}
      directory?(m, p) -> {:ok, :directory}
      true -> {:error, :enoent}
    end
  end

  @doc "Sorted list of all regular file paths in the model — used to verify walk."
  @spec all_files(t()) :: [String.t()]
  def all_files(%__MODULE__{files: files}), do: files |> Map.keys() |> Enum.sort()

  # ── mutations ───────────────────────────────────────────────────────────

  @spec write(t(), String.t(), binary) :: {:ok, t()} | {:error, atom}
  def write(%__MODULE__{} = m, path, content) do
    p = VFS.Path.normalize(path)

    cond do
      directory?(m, p) -> {:error, :eisdir}
      ancestor_is_file?(m, p) -> {:error, :enotdir}
      true -> {:ok, %{m | files: Map.put(m.files, p, content)}}
    end
  end

  @spec rm(t(), String.t(), boolean) :: {:ok, t()} | {:error, atom}
  def rm(%__MODULE__{} = m, path, recursive?) do
    p = VFS.Path.normalize(path)

    cond do
      Map.has_key?(m.files, p) ->
        {:ok, %{m | files: Map.delete(m.files, p)}}

      directory?(m, p) and p != "/" ->
        if recursive?, do: {:ok, rm_recursive(m, p)}, else: {:error, :eisdir}

      p == "/" ->
        if recursive?, do: {:ok, %__MODULE__{}}, else: {:error, :eisdir}

      true ->
        {:error, :enoent}
    end
  end

  @spec mkdir(t(), String.t(), boolean) :: {:ok, t()} | {:error, atom}
  def mkdir(%__MODULE__{} = m, path, parents?) do
    p = VFS.Path.normalize(path)

    cond do
      Map.has_key?(m.files, p) -> {:error, :eexist}
      # Any existing directory — explicit, implicit, or root — is
      # :eexist, except under parents? where mkdir -p no-ops.
      directory?(m, p) -> if parents?, do: {:ok, m}, else: {:error, :eexist}
      ancestor_is_file?(m, p) -> {:error, :enotdir}
      parents? -> {:ok, mkdir_p(m, p)}
      not directory?(m, VFS.Path.dirname(p)) -> {:error, :enoent}
      true -> {:ok, %{m | dirs: MapSet.put(m.dirs, p)}}
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp directory?(_m, "/"), do: true

  defp directory?(%__MODULE__{} = m, path) do
    MapSet.member?(m.dirs, path) or
      has_descendants?(Map.keys(m.files), path) or
      has_descendants?(MapSet.to_list(m.dirs), path)
  end

  defp has_descendants?(paths, dir) do
    prefix = dir <> "/"
    Enum.any?(paths, &String.starts_with?(&1, prefix))
  end

  defp ancestor_is_file?(%__MODULE__{files: files}, path) do
    path |> ancestors() |> Enum.any?(&Map.has_key?(files, &1))
  end

  defp ancestors("/"), do: []

  defp ancestors(path) do
    parent = VFS.Path.dirname(path)
    [parent | ancestors(parent)]
  end

  defp mkdir_p(m, "/"), do: m

  defp mkdir_p(m, path) do
    parent = VFS.Path.dirname(path)
    m = mkdir_p(m, parent)

    if MapSet.member?(m.dirs, path) or directory?(m, path) do
      m
    else
      %{m | dirs: MapSet.put(m.dirs, path)}
    end
  end

  defp rm_recursive(%__MODULE__{} = m, path) do
    prefix = path <> "/"

    files =
      Map.reject(m.files, fn {k, _} -> k == path or String.starts_with?(k, prefix) end)

    dirs =
      m.dirs
      |> MapSet.to_list()
      |> Enum.reject(fn k -> k == path or String.starts_with?(k, prefix) end)
      |> MapSet.new()

    %{m | files: files, dirs: dirs}
  end
end
