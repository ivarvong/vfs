# VFS

A protocol-based virtual filesystem for Elixir. Mount git repos, in-memory
scratch space, and database-backed application state behind one value, then
thread that value through your agent loop the way `Plug.Conn` flows through
a request pipeline.

```elixir
fs =
  VFS.new()
  |> VFS.mount("/", VFS.Memory.new(%{"/repo/README.md" => "hello\n", "/tmp/scratch" => ""}))

{:ok, "hello\n", fs} = VFS.read_file(fs, "/repo/README.md")
{:ok, fs} = VFS.write_file(fs, "/tmp/scratch", "world\n")

# Lazy traversal — composes with Stream.take/2 so an infinite-depth
# backend stays bounded by what the consumer asks for.
2 =
  fs
  |> VFS.walk("/")
  |> Stream.filter(fn {_, %VFS.Stat{type: t}} -> t == :regular end)
  |> Enum.count()

# Structured errors:
{:error, %VFS.Error{kind: :enoent}} = VFS.read_file(fs, "/nope")
```

## Why this and not `File`?

Real-world FS-shaped backends — git repos, S3 buckets, postgres-backed
application data — don't fit `File`. Shimming each one into `File`-like
calls means duplicating mount-routing, error mapping, and cache threading
at every consumer.

`VFS.Mountable` is a single protocol; backends are plain structs that
`defimpl` it. Reads return `{:ok, value, fs}` so lazy backends (a
partial-clone git repo, a paginated S3 lister) populate caches in their
struct on read and the caller threads the updated struct forward. Mount
tables nest because `%VFS{}` itself implements the protocol — composing
multiple backends under one root is `mount/3` calls, no router, no glue.

Pure data, no processes, no global state. The whole FS is a value you
hold; it works inside releases, on Nerves, in Lambda, across distributed
BEAM nodes — anywhere a value travels.

## Non-goals

- **Not a `File` replacement for the host OS.** Use `File` for that.
- **Not POSIX-complete.** No symlinks, hard links, `chmod`, `lstat` in
  v0.1. The protocol is shaped to virtual-FS semantics (git blobs, S3
  objects, DB rows), not OS files.
- **Not a process-backed sandbox.** No `start_link`, no supervision.
  Sandboxing a tool's view of the FS is a job for whatever spawns the
  tool, not for the FS abstraction.

## One-file tour

For a guided walkthrough — every design decision demonstrated in
runnable Elixir, organized around three real agent-loop scenarios —
read [`test/showcase_test.exs`](./test/showcase_test.exs):

```sh
mix test test/showcase_test.exs --trace                                   # local sections
mix test test/showcase_test.exs --trace --include integration_network     # + real github clone
```

Four sections, eight tests, ~365 lines including prose:

1. **Solo agent** — in-memory scratch only.
2. **Read-only codebase** — real git clone via [`:exgit`](https://github.com/ivarvong/exgit).
3. **App service backend** — postgres-shaped (the `VFS.Test.AppService`
   stand-in maps directly to a real `Postgrex`/`Ecto` impl).
4. **The full loop** — codebase + scratch + app service mounted under
   one `%VFS{}` and threaded through five agent steps.

Recommended starting point.

## Worked examples

Real-network demos in [`examples/`](./examples):

```sh
# Structured codesearch: clone anthropics/skills, parse YAML front-matter
# from every SKILL.md, return {name, description, license, path} records.
MIX_ENV=test mix run examples/list_skills.exs

# Regex grep across an arbitrary repo.
MIX_ENV=test mix run examples/grep.exs
```

The `MIX_ENV=test` is required because the `:exgit` backend wrapper
lives in `test/support/`. Production usage will move that defimpl into
`:exgit` itself.

## Status

Pre-1.0. The protocol shape is settled (per [SPEC.md](./SPEC.md)); the
API may adjust before `1.0.0` based on real-world consumer use.
Currently exercised against [`:exgit`](https://github.com/ivarvong/exgit)
in `test/integration/exgit_test.exs` and against a live GitHub clone in
`test/integration/codesearch_smoke_test.exs`. Planned consumers:
[`just_bash`](https://github.com/elixir-ai-tools/just_bash) and
[`pyex`](https://github.com/ivarvong/pyex).

## Performance

Reference numbers in [`bench/baselines.md`](./bench/baselines.md). On an
M3 Max under Elixir 1.20-rc.3:

- `VFS.Path.normalize/1` — 250 ns–1 µs (every public op normalizes once)
- `VFS.Memory.read_file` — 350 ns at 1 KB, 570 ns at 1 MB
- Mount-table dispatch tax — ~1–2 µs/op vs direct backend calls
- `walk` over 10k files — 77 ms (~7 µs/file, linear)

## Installation

```elixir
def deps do
  [{:vfs, github: "ivarvong/vfs"}]
end
```

(Not yet published to hex.pm.)

## Development

```sh
mix setup     # deps + dialyzer PLT
mix check     # format, compile -W, credo, dialyzer, 100% coverage
mix test      # fast loop
```

`mix check` is the gate. CI runs it on every push.

## License

MIT — see [LICENSE](./LICENSE).
