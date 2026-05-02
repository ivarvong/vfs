defmodule VFS.Test.ExgitMount do
  @moduledoc """
  A `VFS.Mountable` defimpl over a real `Exgit.Repository`. Lives in
  `test/support/` for the integration test set; the production version
  will eventually move into `:exgit` itself once the protocol shape is
  stable across two real consumers.

  ## Why a wrapper struct rather than `defimpl ... for: Exgit.Repository`?

  `Exgit.FS` operations require both a `repo` and a `reference`
  (`"HEAD"`, a branch name, or a commit SHA). The `VFS.Mountable`
  protocol is path-only — there's nowhere to thread a ref through
  individual operations.

  Solution: pair `(repo, ref)` in this wrapper. Each mount binds a
  specific ref at construction time:

      {:ok, repo} = Exgit.open("/path/to/repo")
      mount = VFS.Test.ExgitMount.new(repo, "HEAD")
      fs = VFS.new() |> VFS.mount("/repo", mount)

  Mounting the same repository at different paths under different refs
  is supported (and natural):

      fs =
        VFS.new()
        |> VFS.mount("/main",   VFS.Test.ExgitMount.new(repo, "main"))
        |> VFS.mount("/branch", VFS.Test.ExgitMount.new(repo, "feature/x"))

  ## Caveats this surfaced about the protocol

    * **`size` on walk-emitted stats is 0.** Git tree-entry metadata
      doesn't include blob size; only an explicit `stat/2` per path
      gives the real number. We emit 0 with a comment in `walk/3`.
    * **`mtime` is the epoch.** Git blobs aren't dated; only commits
      are. Reasonable consumers treat virtual-FS mtimes as
      backend-defined; we deliberately don't fetch the commit history
      per blob to invent one.
    * **Read-only.** `write_file`/`mkdir`/`rm` return `:erofs`. Real
      git writes (committing) are out of scope for the v0.1 contract.
  """

  @type t :: %__MODULE__{
          repo: Exgit.Repository.t(),
          ref: String.t()
        }

  @enforce_keys [:repo, :ref]
  defstruct [:repo, :ref]

  @doc "Build a new mount over `repo` at `ref` (defaults to `\"HEAD\"`)."
  @spec new(Exgit.Repository.t(), String.t()) :: t()
  def new(repo, ref \\ "HEAD") when is_binary(ref) do
    %__MODULE__{repo: repo, ref: ref}
  end
end

defimpl VFS.Mountable, for: VFS.Test.ExgitMount do
  alias Exgit.FS, as: ExgitFS
  alias Exgit.Object.Blob
  alias VFS.Error
  alias VFS.Stat
  alias VFS.Test.ExgitMount

  @epoch DateTime.from_unix!(0)

  def exists?(%ExgitMount{repo: repo, ref: ref} = mount, path) do
    p = strip_leading(VFS.Path.normalize(path))
    {ExgitFS.exists?(repo, ref, p), mount}
  end

  def stat(%ExgitMount{repo: repo, ref: ref} = mount, path) do
    p = strip_leading(VFS.Path.normalize(path))

    case ExgitFS.stat(repo, ref, p) do
      {:ok, %{type: :blob, size: size}, repo2} ->
        {:ok, %Stat{type: :regular, size: size || 0, mtime: @epoch}, %{mount | repo: repo2}}

      {:ok, %{type: :tree}, repo2} ->
        {:ok, %Stat{type: :directory, size: 0, mtime: @epoch}, %{mount | repo: repo2}}

      {:error, :not_found} ->
        {:error, Error.new(:enoent, path: VFS.Path.normalize(path))}

      {:error, reason} ->
        {:error, Error.new(:eio, path: VFS.Path.normalize(path), message: inspect(reason))}
    end
  end

  def readdir(%ExgitMount{repo: repo, ref: ref} = mount, path) do
    p = strip_leading(VFS.Path.normalize(path))

    case ExgitFS.ls(repo, ref, p) do
      {:ok, entries, repo2} ->
        names =
          entries
          |> Enum.map(fn {_mode, name, _sha} -> name end)
          |> Enum.sort()

        {:ok, names, %{mount | repo: repo2}}

      {:error, :not_found} ->
        {:error, Error.new(:enoent, path: VFS.Path.normalize(path))}

      {:error, :not_a_tree} ->
        {:error, Error.new(:enotdir, path: VFS.Path.normalize(path))}

      {:error, reason} ->
        {:error, Error.new(:eio, path: VFS.Path.normalize(path), message: inspect(reason))}
    end
  end

  def stream_read(%ExgitMount{repo: repo, ref: ref} = mount, path, _opts) do
    p = strip_leading(VFS.Path.normalize(path))

    case ExgitFS.read_path(repo, ref, p) do
      {:ok, {_mode, %Blob{data: data}}, repo2} ->
        {:ok, [data], %{mount | repo: repo2}}

      {:error, :not_found} ->
        {:error, Error.new(:enoent, path: VFS.Path.normalize(path))}

      {:error, :not_a_blob} ->
        {:error, Error.new(:eisdir, path: VFS.Path.normalize(path))}

      {:error, reason} ->
        {:error, Error.new(:eio, path: VFS.Path.normalize(path), message: inspect(reason))}
    end
  end

  def walk(%ExgitMount{repo: repo, ref: ref}, root, _opts) do
    p = strip_leading(VFS.Path.normalize(root))

    repo
    |> ExgitFS.walk(ref)
    |> Stream.flat_map(fn {file_path, _sha} ->
      cond do
        # Walking from repo root: every blob is a hit.
        p == "" ->
          [{"/" <> file_path, blob_stat()}]

        # Walking from a sub-path: keep blobs at or under that prefix.
        file_path == p or String.starts_with?(file_path, p <> "/") ->
          [{"/" <> file_path, blob_stat()}]

        true ->
          []
      end
    end)
  end

  def materialize(%ExgitMount{repo: repo, ref: ref} = mount, _opts) do
    # `Exgit.Repository.materialize/2` converts a lazy partial-clone repo
    # to eager mode (fetches all referenced blobs into the local store
    # AND flips the mode flag). `Exgit.FS.prefetch/3` only populates the
    # cache without flipping the mode, which means subsequent `walk` /
    # `grep` ops still error with `:require_eager!`. We want the full
    # conversion here so `VFS.walk` Just Works after `VFS.materialize`.
    case Exgit.Repository.materialize(repo, ref) do
      {:ok, repo2} ->
        {:ok, %{mount | repo: repo2}}

      {:error, reason} ->
        {:error, Error.new(:eio, message: inspect(reason))}
    end
  end

  def write_file(_, p, _, _), do: {:error, Error.new(:erofs, path: p)}
  def mkdir(_, p, _), do: {:error, Error.new(:erofs, path: p)}
  def rm(_, p, _), do: {:error, Error.new(:erofs, path: p)}

  def capabilities(_), do: MapSet.new([:read, :lazy])

  # ── helpers ──────────────────────────────────────────────────────────

  # Exgit takes paths *without* a leading slash; "" is the root tree.
  defp strip_leading("/"), do: ""
  defp strip_leading("/" <> rest), do: rest

  # Walk-emitted stats: type known, size unknown (git tree entries don't
  # carry size). Consumers needing accurate size call `stat/2` per path.
  defp blob_stat, do: %Stat{type: :regular, size: 0, mtime: @epoch}
end
