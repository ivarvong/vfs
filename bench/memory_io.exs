# VFS.Memory read/write throughput across realistic content sizes.
#
#     mix run bench/memory_io.exs

small = :crypto.strong_rand_bytes(1_024)
medium = :crypto.strong_rand_bytes(64 * 1_024)
large = :crypto.strong_rand_bytes(1_024 * 1_024)

mem_with = fn payload ->
  {:ok, mem} = VFS.Mountable.write_file(VFS.Memory.new(), "/x", payload, [])
  mem
end

inputs = %{
  "1 KB" => {small, mem_with.(small)},
  "64 KB" => {medium, mem_with.(medium)},
  "1 MB" => {large, mem_with.(large)}
}

Benchee.run(
  %{
    "read_file (eager via Memory override)" => fn {_payload, mem} ->
      {:ok, _, _} = VFS.Mountable.stream_read(mem, "/x", []) |> case do
        {:ok, [content], m} -> {:ok, content, m}
        other -> other
      end
    end,
    "stream_read into iodata (default chunk_size=64K)" => fn {_payload, mem} ->
      {:ok, stream, _} = VFS.Mountable.stream_read(mem, "/x", [])
      stream |> Enum.to_list() |> IO.iodata_to_binary()
    end,
    "write_file (overwrite)" => fn {payload, mem} ->
      {:ok, _} = VFS.Mountable.write_file(mem, "/x", payload, [])
    end
  },
  inputs: inputs,
  warmup: 1,
  time: 2,
  memory_time: 1,
  print: [fast_warning: false]
)
