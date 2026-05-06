# Aggregator for CF artifacts lifecycle bench logs.
#
# Reads JSONL emitted by the integration test when
# `CF_BENCH_LOG=/path/runs.jsonl` is set, prints per-op stats.
#
#     mix run bench/cf_aggregate.exs /tmp/cf_runs.jsonl

defmodule CFAggregate do
  @ops [
    :create_repo,
    :mint_token,
    :push_seed,
    :clone_boot,
    :push_modified,
    :clone_rehydrate,
    :delete_repo,
    :total
  ]

  def run([path]) do
    rows =
      path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Enum.map(&Jason.decode!/1)

    n = length(rows)

    series =
      Map.new(@ops, fn op ->
        key = if op == :total, do: "total_ms", else: to_string(op)
        values = for r <- rows, do: get_value(r, op, key)
        {op, values}
      end)

    IO.puts("══════════════════════════════════════════════════════════════════════════════")
    IO.puts(" Cloudflare Artifacts lifecycle — n=#{n}  source=#{path}")
    IO.puts(" Caveat: numbers reflect end-user RTT from the measurement host —")
    IO.puts(" not service SLA, not steady-state, not p99 from a colocated machine.")
    IO.puts("══════════════════════════════════════════════════════════════════════════════")

    header =
      [
        String.pad_trailing("op", 18),
        String.pad_leading("min", 8),
        String.pad_leading("p50", 8),
        String.pad_leading("mean", 8),
        String.pad_leading("p90", 8),
        String.pad_leading("p95", 8),
        String.pad_leading("p99", 8),
        String.pad_leading("max", 8)
      ]
      |> Enum.join("  ")

    IO.puts("  " <> header)
    IO.puts("  " <> String.duplicate("─", String.length(header)))

    for op <- @ops do
      values = Map.fetch!(series, op)
      print_row(op, values)
    end
  end

  def run(_) do
    IO.puts(:stderr, "usage: mix run bench/cf_aggregate.exs <runs.jsonl>")
    System.halt(2)
  end

  defp get_value(row, :total, key), do: Map.fetch!(row, key) |> as_float()

  defp get_value(row, _op, key) do
    row |> Map.fetch!("ops") |> Map.fetch!(key) |> as_float()
  end

  defp as_float(x) when is_float(x), do: x
  defp as_float(x) when is_integer(x), do: x * 1.0

  defp print_row(op, values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    sum = Enum.sum(sorted)
    mean = sum / n
    min = List.first(sorted)
    max = List.last(sorted)
    p50 = percentile(sorted, 0.50)
    p90 = percentile(sorted, 0.90)
    p95 = percentile(sorted, 0.95)
    p99 = percentile(sorted, 0.99)

    cells =
      [
        String.pad_trailing(to_string(op), 18),
        fmt(min),
        fmt(p50),
        fmt(mean),
        fmt(p90),
        fmt(p95),
        fmt(p99),
        fmt(max)
      ]
      |> Enum.join("  ")

    IO.puts("  " <> cells)
  end

  defp percentile(sorted, q) do
    n = length(sorted)
    idx = max(0, min(n - 1, round(q * (n - 1))))
    Enum.at(sorted, idx)
  end

  defp fmt(x), do: :io_lib.format(~c"~8.1f", [x]) |> IO.iodata_to_binary()
end

CFAggregate.run(System.argv())
