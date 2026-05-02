defmodule VFS.Error do
  @moduledoc """
  Structured error returned by every fallible `VFS.Mountable` op.

  ## Fields

    * `:kind`    — atom from the `kind/0` type. The primary control-flow value;
      pattern-match on this.
    * `:path`    — the path that failed, as the *user* expressed it (before
      mount-prefix stripping). May be `nil` for ops that don't take a path.
    * `:mount`   — the mountpoint that handled the op, if any. Useful for
      log context in mount-table dispatch.
    * `:message` — human-readable; defaults to a sensible string built from
      the other fields.

  ## Examples

      iex> {:error, err} = VFS.read_file(VFS.new(), "/nope")
      iex> err.kind
      :enoent

  Raisable for `!`-style helpers:

      iex> raise VFS.Error, kind: :enoent, path: "/foo"
      ** (VFS.Error) :enoent at /foo
  """

  defexception [:kind, :path, :mount, :message]

  @typedoc """
  POSIX-style error kinds, kept tight on purpose. Pattern match on these
  for flow control.

    * `:enoent`   — path doesn't exist
    * `:eexist`   — path already exists (e.g. `mkdir` collision)
    * `:eisdir`   — expected a file, got a directory
    * `:enotdir`  — expected a directory, got a file
    * `:erofs`    — the mount or wrapper is read-only
    * `:enotsup`  — the backend doesn't support this op
    * `:eacces`   — permission denied
    * `:einval`   — bad argument (e.g. malformed path or option)
    * `:exdev`    — cross-mount op that can't be atomic
    * `:eio`      — underlying I/O failure
    * `:eloop`    — symlink loop
  """
  @type kind ::
          :enoent
          | :eexist
          | :eisdir
          | :enotdir
          | :erofs
          | :enotsup
          | :eacces
          | :einval
          | :exdev
          | :eio
          | :eloop

  @type t :: %__MODULE__{
          kind: kind,
          path: String.t() | nil,
          mount: String.t() | nil,
          message: String.t() | nil
        }

  @impl true
  def exception(opts) when is_list(opts) do
    kind = Keyword.fetch!(opts, :kind)
    path = Keyword.get(opts, :path)
    mount = Keyword.get(opts, :mount)
    message = Keyword.get(opts, :message) || default_message(kind, path)

    %__MODULE__{kind: kind, path: path, mount: mount, message: message}
  end

  @impl true
  def message(%__MODULE__{message: msg}) when is_binary(msg), do: msg
  def message(%__MODULE__{kind: kind, path: path}), do: default_message(kind, path)

  @doc """
  Build an error struct without raising. Convenience constructor for
  backends and the mount-table dispatcher.
  """
  @spec new(kind, keyword) :: t()
  def new(kind, opts \\ []) when is_atom(kind) do
    exception([{:kind, kind} | opts])
  end

  @doc """
  Add or overwrite the `:mount` field on an existing error. Used by the
  mount-table dispatcher to attach mount context to errors bubbled up
  from leaf backends.
  """
  @spec put_mount(t(), String.t()) :: t()
  def put_mount(%__MODULE__{} = err, mount) when is_binary(mount) do
    %{err | mount: mount}
  end

  defp default_message(kind, nil), do: inspect(kind)
  defp default_message(kind, path), do: "#{inspect(kind)} at #{path}"
end
