# Lazy backend cache hit/miss costs.
# GitFake demonstrates the realistic shape: cache lookup by SHA, fetch
# from the "remote" (in-memory map) on miss.
#
#     mix run bench/lazy_cache.exs

alias VFS.Test.GitFake

repo = GitFake.commit(%{"/a" => "hello", "/b" => "world"})

# Pre-warmed copy: cache is populated; every read is a hit.
{:ok, warm} = VFS.Mountable.materialize(repo, [])

read = fn r, path ->
  case VFS.Mountable.stream_read(r, path, []) do
    {:ok, [c], r2} -> {:ok, c, r2}
    other -> other
  end
end

Benchee.run(
  %{
    "cold miss (cache empty)" => fn -> read.(repo, "/a") end,
    "warm hit (cache pre-populated)" => fn -> read.(warm, "/a") end,
    "miss-then-hit (state threaded)" => fn ->
      {:ok, _, r2} = read.(repo, "/a")
      {:ok, _, _} = read.(r2, "/a")
    end
  },
  warmup: 1,
  time: 2,
  memory_time: 1,
  print: [fast_warning: false]
)
