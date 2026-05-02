# Walk throughput — how fast can we enumerate a tree?
#
#     mix run bench/walk.exs

build_tree = fn n_files ->
  Enum.reduce(1..n_files, VFS.Memory.new(), fn i, mem ->
    # bucket files into 100 buckets of 100 to get a non-trivial tree shape
    path = "/dir_#{rem(i, 100)}/file_#{i}"
    {:ok, mem2} = VFS.Mountable.write_file(mem, path, "", [])
    mem2
  end)
end

inputs = %{
  "100 files" => build_tree.(100),
  "1000 files" => build_tree.(1_000),
  "10000 files" => build_tree.(10_000)
}

Benchee.run(
  %{
    "walk + Enum.count (no map)" => fn fs ->
      fs |> VFS.Mountable.walk("/", []) |> Enum.count()
    end,
    "walk + map paths + sort" => fn fs ->
      fs |> VFS.Mountable.walk("/", []) |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    end,
    "walk through mount table" => fn fs ->
      mt = VFS.new() |> VFS.mount("/", fs)
      mt |> VFS.walk("/") |> Enum.count()
    end
  },
  inputs: inputs,
  warmup: 1,
  time: 3,
  print: [fast_warning: false]
)
