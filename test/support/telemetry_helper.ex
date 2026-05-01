defmodule VFS.Test.TelemetryHelper do
  @moduledoc false
  # Helpers for asserting telemetry events were emitted with expected
  # metadata/measurements. Attaches a forwarder handler that sends events
  # to the calling process; the test then `assert_receive`s.

  @doc """
  Attach a handler that forwards events under `events` to the calling
  process. `events` is a list of full event names (each itself a list of
  atoms, e.g. `[:vfs, :read_file, :start]`).

  Prefix-form (e.g. `[:vfs, :read_file]`) auto-expands to its `:start`,
  `:stop`, and `:exception` triple. Disable expansion with `expand: false`.

  Returns a unique handler id; tests should detach via `detach/1` (or use
  `attach!/1,2` to auto-detach on test exit).
  """
  def attach(events, opts \\ []) when is_list(events) do
    expanded =
      if Keyword.get(opts, :expand, true) do
        Enum.flat_map(events, fn ev ->
          if is_list(ev) and List.last(ev) in [:start, :stop, :exception, :hit, :miss] do
            [ev]
          else
            [ev ++ [:start], ev ++ [:stop], ev ++ [:exception]]
          end
        end)
      else
        events
      end

    handler_id =
      Keyword.get(opts, :name, "vfs-test-#{System.unique_integer([:positive])}")

    :ok =
      :telemetry.attach_many(handler_id, expanded, &__MODULE__.forward/4, %{test_pid: self()})

    handler_id
  end

  @doc "Same as `attach/2` but auto-detaches on test exit."
  def attach!(events, opts \\ []) do
    id = attach(events, opts)
    ExUnit.Callbacks.on_exit(fn -> detach(id) end)
    id
  end

  def detach(handler_id), do: :telemetry.detach(handler_id)

  @doc false
  def forward(event, measurements, metadata, %{test_pid: pid}) do
    send(pid, {:telemetry, event, measurements, metadata})
  end
end
