defmodule VFS.Test.AppService do
  @moduledoc """
  A fake, in-process stand-in for a **postgres-backed application
  service** exposed through `VFS.Mountable`. Lives in `test/support/`
  because it's a worked example, not a production backend.

  Shape of the production version this stands in for:

    * `storage` is a postgres table — `paths(path PRIMARY KEY, content BYTEA,
      updated_at TIMESTAMPTZ)` — accessed via `Postgrex` or `Ecto`.
    * Reads `SELECT content FROM paths WHERE path = $1`.
    * Writes are `INSERT ... ON CONFLICT (path) DO UPDATE`.
    * `cache` is a per-`%VFS{}`-value cache that survives across reads
      *of the same connection-tagged value*, threaded back through the
      protocol's `{:ok, ..., impl}` return shape.
    * `materialize/2` runs `SELECT path, content FROM paths
      WHERE path LIKE $1 || '%'` to load a working set in one round-trip
      before bulk reads.

  The fake replaces the postgres calls with a `Map` so the showcase
  doesn't need a database, but the protocol surface and call sites are
  identical. To productionize: implement the same callbacks against
  a real `Postgrex.Connection`.

  ## Why this shape for an application service

  Agent-loop applications need to address user-scoped state by path
  (`/users/U123/profile.json`, `/conversations/C42/messages.jsonl`,
  `/sessions/S99/state.json`). Postgres is the right storage for that
  data — durable, indexed, transactional, multi-tenant — but the
  abstraction the agent code talks to should be the same `VFS` value
  it uses for everything else, so the same retrieval/grep/walk
  primitives compose across every backend.

  ## Differences from a filesystem

  Application data is **flat-keyed**, not hierarchical. There are no
  empty directories — a "directory" is any prefix that has keys under
  it, mirroring S3. `mkdir/3` returns `:enotsup`; consumers don't need
  empty directories in a postgres-backed store.
  """

  @type t :: %__MODULE__{
          storage: %{VFS.Path.t() => binary},
          cache: %{VFS.Path.t() => binary},
          hits: non_neg_integer(),
          misses: non_neg_integer()
        }

  defstruct storage: %{}, cache: %{}, hits: 0, misses: 0

  @doc """
  Build an empty app service. Optionally seed `storage` to simulate
  data that was already in the table when this connection opened.
  """
  @spec new(%{optional(String.t()) => binary}) :: t()
  def new(seed \\ %{}) when is_map(seed) do
    storage = for {k, v} <- seed, into: %{}, do: {VFS.Path.normalize(k), v}
    %__MODULE__{storage: storage}
  end
end

defimpl VFS.Mountable, for: VFS.Test.AppService do
  use VFS.Skeleton

  alias VFS.Error
  alias VFS.Stat
  alias VFS.Test.AppService

  @epoch DateTime.from_unix!(0)

  def exists?(%AppService{storage: storage} = svc, path) do
    p = VFS.Path.normalize(path)
    {Map.has_key?(storage, p) or directory?(storage, p), svc}
  end

  def stat(%AppService{storage: storage} = svc, path) do
    p = VFS.Path.normalize(path)

    cond do
      Map.has_key?(storage, p) ->
        size = storage |> Map.fetch!(p) |> byte_size()
        {:ok, %Stat{type: :regular, size: size, mtime: @epoch}, svc}

      p == "/" or directory?(storage, p) ->
        {:ok, %Stat{type: :directory, size: 0, mtime: @epoch}, svc}

      true ->
        {:error, Error.new(:enoent, path: p)}
    end
  end

  def readdir(%AppService{storage: storage} = svc, path) do
    p = VFS.Path.normalize(path)

    cond do
      p == "/" or directory?(storage, p) ->
        prefix = if p == "/", do: "/", else: p <> "/"

        names =
          storage
          |> Map.keys()
          |> Enum.flat_map(fn key ->
            if String.starts_with?(key, prefix) and key != prefix do
              rest = String.replace_prefix(key, prefix, "")
              [rest |> String.split("/", parts: 2) |> hd()]
            else
              []
            end
          end)
          |> Enum.uniq()
          |> Enum.sort()

        {:ok, names, svc}

      Map.has_key?(storage, p) ->
        {:error, Error.new(:enotdir, path: p)}

      true ->
        {:error, Error.new(:enoent, path: p)}
    end
  end

  def stream_read(%AppService{} = svc, path, opts) do
    p = VFS.Path.normalize(path)

    cond do
      # Path is a known file (in cache or storage): fetch + apply opts.
      Map.has_key?(svc.cache, p) or Map.has_key?(svc.storage, p) ->
        {content, svc} = fetch_with_cache(svc, p)

        case VFS.StreamOptions.apply(content, opts) do
          {:ok, stream} -> {:ok, stream, svc}
          {:error, reason} -> {:error, Error.new(reason, path: p)}
        end

      directory?(svc.storage, p) ->
        {:error, Error.new(:eisdir, path: p)}

      true ->
        {:error, Error.new(:enoent, path: p)}
    end
  end

  defp fetch_with_cache(%AppService{} = svc, p) do
    case Map.fetch(svc.cache, p) do
      {:ok, content} ->
        :telemetry.execute([:vfs, :cache, :hit], %{}, %{path: p, impl: AppService})
        {content, %{svc | hits: svc.hits + 1}}

      :error ->
        content = Map.fetch!(svc.storage, p)
        # Simulates the SELECT round-trip; populate the cache so
        # subsequent reads of this path on this connection are free.
        :telemetry.execute([:vfs, :cache, :miss], %{}, %{path: p, impl: AppService})

        {content, %{svc | cache: Map.put(svc.cache, p, content), misses: svc.misses + 1}}
    end
  end

  def write_file(%AppService{} = svc, path, content, _opts) when is_binary(content) do
    p = VFS.Path.normalize(path)

    if directory?(svc.storage, p) do
      {:error, Error.new(:eisdir, path: p)}
    else
      # Simulates an UPSERT. Cache for this path stays warm with the
      # new content, so a subsequent read returns it immediately.
      {:ok,
       %{
         svc
         | storage: Map.put(svc.storage, p, content),
           cache: Map.put(svc.cache, p, content)
       }}
    end
  end

  # Postgres-backed flat key stores have no empty directories.
  def mkdir(_, p, _), do: {:error, Error.new(:enotsup, path: p)}

  def rm(%AppService{} = svc, path, opts) do
    p = VFS.Path.normalize(path)
    recursive? = Keyword.get(opts, :recursive, false)

    cond do
      Map.has_key?(svc.storage, p) ->
        {:ok, %{svc | storage: Map.delete(svc.storage, p), cache: Map.delete(svc.cache, p)}}

      directory?(svc.storage, p) and recursive? ->
        prefix = p <> "/"

        keep = fn k -> not (k == p or String.starts_with?(k, prefix)) end

        {:ok,
         %{
           svc
           | storage: Map.filter(svc.storage, fn {k, _} -> keep.(k) end),
             cache: Map.filter(svc.cache, fn {k, _} -> keep.(k) end)
         }}

      directory?(svc.storage, p) ->
        {:error, Error.new(:eisdir, path: p)}

      true ->
        {:error, Error.new(:enoent, path: p)}
    end
  end

  @doc """
  Prefetch every path under a prefix into the cache in one batch.
  Production version: a single `SELECT path, content FROM paths
  WHERE path LIKE $1 || '%'` followed by a bulk `Map.merge` into the
  cache. The fake skips the round-trip and just copies.

  Pass `prefix:` to scope the prefetch (highly recommended for big
  tables); default is everything.
  """
  def materialize(%AppService{} = svc, opts) do
    prefix = Keyword.get(opts, :prefix, "/")
    norm = VFS.Path.normalize(prefix)
    match = if norm == "/", do: "/", else: norm <> "/"

    addition =
      svc.storage
      |> Enum.filter(fn {k, _} -> k == norm or String.starts_with?(k, match) end)
      |> Map.new()

    {:ok, %{svc | cache: Map.merge(svc.cache, addition)}}
  end

  def capabilities(_), do: MapSet.new([:read, :write, :lazy])

  # ── helpers ──

  defp directory?(_storage, "/"), do: true

  defp directory?(storage, path) do
    prefix = path <> "/"
    Enum.any?(Map.keys(storage), &String.starts_with?(&1, prefix))
  end
end
