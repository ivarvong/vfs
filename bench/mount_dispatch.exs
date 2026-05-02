# Mount-table dispatch overhead: how much do we pay for going through
# the mount table vs. calling the backend directly?
#
#     mix run bench/mount_dispatch.exs

mem = VFS.Memory.new(%{"/a" => "x", "/sub/b" => "y"})

direct = mem
mt_root = VFS.new() |> VFS.mount("/", mem)
mt_deep = VFS.new() |> VFS.mount("/sub/deep/repo", mem)

# Build a many-mount table (10 mounts, target is the longest-prefix one)
many_mt =
  Enum.reduce(0..9, VFS.new(), fn i, vfs ->
    VFS.mount(vfs, "/m#{i}", VFS.Memory.new(%{"/a" => "x"}))
  end)
  |> VFS.mount("/m9/deep", mem)

Benchee.run(
  %{
    "direct backend read_file" => fn ->
      {:ok, _, _} =
        case VFS.Mountable.stream_read(direct, "/a", []) do
          {:ok, [c], m} -> {:ok, c, m}
          other -> other
        end
    end,
    "mount table (1 mount, root)" => fn ->
      {:ok, _, _} = VFS.read_file(mt_root, "/a")
    end,
    "mount table (1 mount, deep mountpoint)" => fn ->
      {:ok, _, _} = VFS.read_file(mt_deep, "/sub/deep/repo/a")
    end,
    "mount table (10 mounts, longest-prefix match)" => fn ->
      {:ok, _, _} = VFS.read_file(many_mt, "/m9/deep/a")
    end
  },
  warmup: 1,
  time: 2,
  print: [fast_warning: false]
)
