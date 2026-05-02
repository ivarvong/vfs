defmodule VFS.Test.GitFake do
  @moduledoc """
  Fake "git-like" backend — read-only, content-addressed, lazy.

  Models the shape of a real exgit-style backend without the network or
  the actual git plumbing. The point is to verify that the v0.1 protocol
  surface (state threading, `materialize/2`, capability declarations,
  cache-event telemetry) actually composes for a real-world content-
  addressed lazy backend, *and* to give implementers a concrete example
  to study before they write the real thing.

  ## Structure

  A `%GitFake{}` represents a single commit:

    * `tree`    — `%{path => {sha, size}}`. Maps each path to the SHA of its
                  blob and the blob's byte size. Tracking size in the tree
                  means `stat/2` doesn't have to fetch the blob — mirrors
                  real-world git workflows where a `git ls-tree` gives you
                  size without inflating blobs.
    * `objects` — `%{sha => binary}`. The "remote object store" — what
                  you'd fetch from across the network in a real repo.
                  In this fake, everything's in memory; we *pretend* the
                  fetch has cost.
    * `cache`   — `%{sha => binary}`. Locally-fetched blobs. A read on a
                  path looks up its SHA in `tree`, then checks `cache`;
                  miss fetches from `objects` and populates `cache`.
    * `hits` / `misses` — counters surfacing for tests; these prove that
                  state threading actually preserves the cache across
                  reads.

  ## What this exercises in the protocol

    * **State threading.** Every read returns an updated `GitFake` with
      cache populated. Threading state forward turns N reads of the
      same path into 1 miss + (N-1) hits; throwing state away makes
      every read a miss. The `state_threading_test.exs` style proves this.

    * **`materialize/2`.** Pre-fetches every blob referenced by the tree
      into `cache` in one shot. After materialize, all reads are hits.
      The agent-loop pattern: pre-warm before bulk work.

    * **Read-only enforcement.** All mutations return
      `{:error, %VFS.Error{kind: :erofs}}`. The capability set is
      `MapSet.new([:read, :lazy])`; consumers that check capabilities
      know not to attempt writes.

    * **Cache event telemetry.** Each read emits `[:vfs, :cache, :hit]` or
      `[:vfs, :cache, :miss]` with `%{path: ..., impl: ...}` metadata.
      Lets a real exgit impl plug into the same observability story.

  ## Usage

      iex> repo = VFS.Test.GitFake.commit(%{
      ...>   "/README.md"  => "hello",
      ...>   "/src/lib.ex" => "defmodule Lib do end"
      ...> })
      iex> {:ok, "hello", repo} = VFS.Mountable.read_file(repo, "/README.md")
      iex> repo.misses
      1
      iex> repo.hits
      0
      iex> {:ok, "hello", repo} = VFS.Mountable.read_file(repo, "/README.md")
      iex> {repo.misses, repo.hits}
      {1, 1}
  """

  @type sha :: String.t()
  @type t :: %__MODULE__{
          tree: %{VFS.Path.t() => {sha, non_neg_integer()}},
          objects: %{sha => binary},
          cache: %{sha => binary},
          hits: non_neg_integer(),
          misses: non_neg_integer()
        }

  defstruct tree: %{}, objects: %{}, cache: %{}, hits: 0, misses: 0

  @doc """
  Build a fresh "commit" from a map of path → content.

  Hashes each unique content with SHA-256, populates `objects`, and
  builds a `tree` mapping every path to its `{sha, size}`. Identical
  contents at different paths share the same SHA — the content-
  addressed property — so the cache fills more efficiently than a
  by-path cache would.

  ## Examples

      iex> repo = VFS.Test.GitFake.commit(%{"/a" => "x", "/b" => "x"})
      iex> map_size(repo.objects)
      1
      iex> map_size(repo.tree)
      2
  """
  @spec commit(%{optional(String.t()) => binary}) :: t()
  def commit(files) when is_map(files) do
    Enum.reduce(files, %__MODULE__{}, fn {path, content}, repo ->
      norm = VFS.Path.normalize(path)
      sha = sha_of(content)

      %{
        repo
        | tree: Map.put(repo.tree, norm, {sha, byte_size(content)}),
          objects: Map.put(repo.objects, sha, content)
      }
    end)
  end

  @doc "Compute the SHA-256 hex digest of `content` — the content-address key."
  @spec sha_of(binary) :: sha
  def sha_of(content) when is_binary(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end
end

defimpl VFS.Mountable, for: VFS.Test.GitFake do
  use VFS.Skeleton

  alias VFS.Error
  alias VFS.Stat
  alias VFS.Test.GitFake

  @epoch DateTime.from_unix!(0)

  def exists?(%GitFake{} = repo, path) do
    p = VFS.Path.normalize(path)
    {Map.has_key?(repo.tree, p) or has_descendants?(repo, p), repo}
  end

  def stat(%GitFake{} = repo, path) do
    p = VFS.Path.normalize(path)

    cond do
      Map.has_key?(repo.tree, p) ->
        {_sha, size} = Map.fetch!(repo.tree, p)
        {:ok, %Stat{type: :regular, size: size, mtime: @epoch}, repo}

      p == "/" or has_descendants?(repo, p) ->
        {:ok, %Stat{type: :directory, size: 0, mtime: @epoch}, repo}

      true ->
        {:error, Error.new(:enoent, path: p)}
    end
  end

  def readdir(%GitFake{} = repo, path) do
    p = VFS.Path.normalize(path)

    cond do
      p == "/" or has_descendants?(repo, p) ->
        prefix = if p == "/", do: "/", else: p <> "/"

        names =
          repo.tree
          |> Map.keys()
          |> children_under(prefix)
          |> Enum.uniq()
          |> Enum.sort()

        {:ok, names, repo}

      Map.has_key?(repo.tree, p) ->
        {:error, Error.new(:enotdir, path: p)}

      true ->
        {:error, Error.new(:enoent, path: p)}
    end
  end

  def stream_read(%GitFake{} = repo, path, _opts) do
    p = VFS.Path.normalize(path)

    case Map.fetch(repo.tree, p) do
      {:ok, {sha, _size}} ->
        {content, repo} = fetch_blob(repo, sha, p)
        {:ok, [content], repo}

      :error ->
        if has_descendants?(repo, p),
          do: {:error, Error.new(:eisdir, path: p)},
          else: {:error, Error.new(:enoent, path: p)}
    end
  end

  def materialize(%GitFake{} = repo, _opts) do
    # Pre-fetch every blob referenced by the tree into the cache. After
    # this, no read incurs a miss. This is the lever the agent loop
    # pulls before doing bulk work — one batch fetch beats N round trips.
    referenced = for {sha, _size} <- Map.values(repo.tree), into: %{}, do: {sha, true}

    cache =
      Enum.reduce(repo.objects, repo.cache, fn {sha, content}, acc ->
        if Map.has_key?(referenced, sha), do: Map.put(acc, sha, content), else: acc
      end)

    {:ok, %{repo | cache: cache}}
  end

  def write_file(_, p, _, _), do: {:error, Error.new(:erofs, path: p)}
  def mkdir(_, p, _), do: {:error, Error.new(:erofs, path: p)}
  def rm(_, p, _), do: {:error, Error.new(:erofs, path: p)}

  def capabilities(_), do: MapSet.new([:read, :lazy])

  # ── helpers ──────────────────────────────────────────────────────────

  defp fetch_blob(%GitFake{cache: cache} = repo, sha, path) do
    case Map.fetch(cache, sha) do
      {:ok, content} ->
        :telemetry.execute([:vfs, :cache, :hit], %{}, %{path: path, impl: GitFake})
        {content, %{repo | hits: repo.hits + 1}}

      :error ->
        # Simulate a "fetch" — in a real backend this would round-trip
        # to the network. Here we just look it up in the in-memory
        # objects store, but the cache-update + telemetry path is
        # identical to what exgit would do.
        content = Map.fetch!(repo.objects, sha)
        :telemetry.execute([:vfs, :cache, :miss], %{}, %{path: path, impl: GitFake})

        {content, %{repo | cache: Map.put(cache, sha, content), misses: repo.misses + 1}}
    end
  end

  defp has_descendants?(%GitFake{tree: tree}, dir) do
    prefix = if dir == "/", do: "/", else: dir <> "/"
    Enum.any?(Map.keys(tree), &String.starts_with?(&1, prefix))
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
