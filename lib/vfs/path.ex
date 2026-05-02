defmodule VFS.Path do
  @moduledoc """
  Pure path utilities for `VFS`.

  All public ops on `VFS` and the `VFS.Mountable` protocol expect absolute,
  already-normalized paths with a leading `/`. This module is the canonical
  place for path manipulation; backends should not roll their own.

  Paths are POSIX-shaped: `/`-separated, with `.` (current) and `..` (parent)
  segments collapsed by `normalize/1`. `..` at the root is a no-op (root is
  its own parent), matching POSIX semantics.
  """

  @typedoc "An absolute, normalized path with a leading `/` and no trailing slash (except root)."
  @type t :: String.t()

  @doc """
  Normalize an absolute path: collapse `.` and `..` segments and remove
  consecutive slashes. The result has a leading `/` and no trailing slash
  except for the root.

  Raises `ArgumentError` on non-absolute input.

  ## Examples

      iex> VFS.Path.normalize("/foo/./bar/../baz")
      "/foo/baz"

      iex> VFS.Path.normalize("//foo//bar/")
      "/foo/bar"

      iex> VFS.Path.normalize("/")
      "/"

      iex> VFS.Path.normalize("/../foo")
      "/foo"
  """
  @spec normalize(String.t()) :: t()
  def normalize("/" <> _ = path) do
    case path |> String.split("/", trim: true) |> normalize_segments([]) do
      [] -> "/"
      segs -> "/" <> Enum.join(segs, "/")
    end
  end

  def normalize(other) do
    raise ArgumentError, "VFS paths must be absolute (start with `/`); got: #{inspect(other)}"
  end

  defp normalize_segments([], acc), do: :lists.reverse(acc)
  defp normalize_segments(["." | rest], acc), do: normalize_segments(rest, acc)
  defp normalize_segments([".." | rest], [_ | tail]), do: normalize_segments(rest, tail)
  defp normalize_segments([".." | rest], []), do: normalize_segments(rest, [])
  defp normalize_segments([seg | rest], acc), do: normalize_segments(rest, [seg | acc])

  @doc """
  Returns true if `path` starts with `/`.

  ## Examples

      iex> VFS.Path.absolute?("/foo")
      true

      iex> VFS.Path.absolute?("foo")
      false
  """
  @spec absolute?(String.t()) :: boolean
  def absolute?("/" <> _), do: true
  def absolute?(_), do: false

  @doc """
  Split a normalized path into its segments. The root splits to `[]`.

  ## Examples

      iex> VFS.Path.split("/foo/bar/baz")
      ["foo", "bar", "baz"]

      iex> VFS.Path.split("/")
      []
  """
  @spec split(t()) :: [String.t()]
  def split("/"), do: []
  def split("/" <> rest), do: String.split(rest, "/", trim: true)

  @doc """
  Join an absolute base with a relative or absolute path. The result is
  normalized. If `path` is itself absolute, the base is ignored (matches
  `Path.join/2` behavior).

  ## Examples

      iex> VFS.Path.join("/foo", "bar")
      "/foo/bar"

      iex> VFS.Path.join("/foo/bar", "../baz")
      "/foo/baz"

      iex> VFS.Path.join("/foo", "/abs/ignored-base")
      "/abs/ignored-base"
  """
  @spec join(t(), String.t()) :: t()
  def join(_base, "/" <> _ = abs), do: normalize(abs)
  def join(base, rel) when is_binary(rel), do: normalize(strip_trailing(base) <> "/" <> rel)

  defp strip_trailing("/"), do: ""
  defp strip_trailing(p), do: String.trim_trailing(p, "/")

  @doc """
  Parent directory. The parent of `/` is `/` (POSIX semantics).

  ## Examples

      iex> VFS.Path.dirname("/foo/bar")
      "/foo"

      iex> VFS.Path.dirname("/foo")
      "/"

      iex> VFS.Path.dirname("/")
      "/"
  """
  @spec dirname(t()) :: t()
  def dirname("/"), do: "/"

  def dirname(path) do
    case split(path) do
      [_only] -> "/"
      segs -> "/" <> (segs |> Enum.drop(-1) |> Enum.join("/"))
    end
  end

  @doc """
  Last segment of a path. The basename of the root is the empty string.

  ## Examples

      iex> VFS.Path.basename("/foo/bar")
      "bar"

      iex> VFS.Path.basename("/")
      ""
  """
  @spec basename(t()) :: String.t()
  def basename("/"), do: ""
  def basename(path), do: path |> split() |> List.last()

  @doc """
  Re-root `path` under `prefix`, returning the remainder as an absolute path
  under the new root. Returns `:error` when `prefix` is not a path-segment
  prefix of `path`. Used for mount-prefix stripping.

  ## Examples

      iex> VFS.Path.relative_to("/foo/bar/baz", "/foo")
      {:ok, "/bar/baz"}

      iex> VFS.Path.relative_to("/foo/bar", "/foo/bar")
      {:ok, "/"}

      iex> VFS.Path.relative_to("/foo/bar", "/")
      {:ok, "/foo/bar"}

      iex> VFS.Path.relative_to("/foobar", "/foo")
      :error
  """
  @spec relative_to(t(), t()) :: {:ok, t()} | :error
  def relative_to(path, "/"), do: {:ok, normalize(path)}

  def relative_to(path, prefix) do
    p = normalize(path)
    pre = normalize(prefix)

    cond do
      p == pre -> {:ok, "/"}
      String.starts_with?(p, pre <> "/") -> {:ok, String.replace_prefix(p, pre, "")}
      true -> :error
    end
  end
end
