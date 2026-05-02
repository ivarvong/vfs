defmodule VFS.StreamOptions do
  @moduledoc """
  Helper module for backend authors implementing `stream_read/3`. Applies
  the documented options (`:chunk_size`, `:byte_range`, `:line_range`) to
  a binary content and returns a chunk Stream — or `{:error, :einval}`
  for malformed options.

  Every backend whose `stream_read/3` returns bytes (memory-backed,
  postgres-backed, S3-backed, blob-store-backed) wants the same option
  handling. Centralizing it here means:

    * No backend silently ignores documented options.
    * Validation is uniform — `:einval` triggers identical conditions
      across every backend, which the conformance suite enforces.
    * Bug fixes propagate to every backend (e.g. the `:line_range`
      `last < first` validation).

  Usage from a `defimpl VFS.Mountable` block:

      def stream_read(%MyBackend{} = b, path, opts) do
        case fetch_content(b, path) do
          {:ok, content} ->
            case VFS.StreamOptions.apply(content, opts) do
              {:ok, stream} -> {:ok, stream, b}
              {:error, kind} -> {:error, VFS.Error.new(kind, path: path)}
            end

          :error ->
            {:error, VFS.Error.new(:enoent, path: path)}
        end
      end
  """

  @default_chunk_size 64 * 1024

  @doc """
  Apply `:chunk_size`, `:byte_range`, and `:line_range` options to
  `content`, returning `{:ok, chunk_stream}` or `{:error, :einval}`.

  Order of operations: byte slice → line slice → chunk. So
  `byte_range: {0, 100}, line_range: {1, 5}` means "first 100 bytes,
  then take the first 5 lines of those." Mixing both is unusual but
  the order is documented for predictability.
  """
  @spec apply(binary, keyword) :: {:ok, Enumerable.t(binary)} | {:error, :einval}
  def apply(content, opts) when is_binary(content) and is_list(opts) do
    with {:ok, chunk_size} <- validate_chunk_size(opts),
         {:ok, sliced} <- apply_byte_range(content, opts),
         {:ok, sliced} <- apply_line_range(sliced, opts) do
      {:ok, chunk_stream(sliced, chunk_size)}
    end
  end

  # ── chunk_size ───────────────────────────────────────────────────────

  defp validate_chunk_size(opts) do
    case Keyword.get(opts, :chunk_size, @default_chunk_size) do
      n when is_integer(n) and n > 0 -> {:ok, n}
      _ -> {:error, :einval}
    end
  end

  # ── byte_range ───────────────────────────────────────────────────────

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

  # ── line_range ──────────────────────────────────────────────────────
  #
  # 1-based inclusive `{first, last}`. `last == :end` reads to EOF.
  # When `last` is an integer, it must satisfy `last >= first` AND
  # `last >= 1`. Anything else is `:einval` — silent-empty would be
  # the worst possible behavior for an LLM tool boundary that uses
  # line ranges to retrieve precise context windows.

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

  defp slice_lines(content, first, :end) do
    lines = String.split(content, "\n")
    sliced = lines |> Enum.slice((first - 1)..(length(lines) - 1)//1) |> Enum.join("\n")
    {:ok, sliced}
  end

  defp slice_lines(content, first, last)
       when is_integer(last) and last >= first and last >= 1 do
    lines = String.split(content, "\n")
    sliced = lines |> Enum.slice((first - 1)..(last - 1)//1) |> Enum.join("\n")
    {:ok, sliced}
  end

  defp slice_lines(_content, _first, _last), do: {:error, :einval}

  # ── chunking ────────────────────────────────────────────────────────

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
