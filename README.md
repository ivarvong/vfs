# VFS

Protocol-based virtual filesystem for the Elixir AI tools stack. Pluggable
backends, state-threading reads, lazy primitives, and a tiny core surface
designed to be passed back and forth across an agent loop.

```elixir
fs = VFS.new(%{"/repo/README.md" => "hello\n", "/tmp/scratch" => ""})

{:ok, "hello\n", fs} = VFS.read_file(fs, "/repo/README.md")
{:ok, fs} = VFS.write_file(fs, "/tmp/scratch", "world\n")

# Lazy traversal — memory-bounded over arbitrarily large trees.
fs
|> VFS.walk("/", [])
|> Stream.filter(fn {_, %VFS.Stat{type: t}} -> t == :regular end)
|> Enum.count()
```

## Why

`VFS.Mountable` is a single protocol. Every backend is a struct that
`defimpl`s it. Every operation — including reads — returns the (possibly
updated) impl as the last element of its success tuple, so lazy backend
caches survive across reads. Mount tables nest, because `%VFS{}` itself
implements the protocol.

See [SPEC.md](./SPEC.md) for the full design rationale.

## Status

Pre-1.0. The protocol shape is settled (per `SPEC.md`); the API may still
adjust before `1.0.0` based on the first wave of consumers (`just_bash`,
`pyex`, `exgit`).

## Installation

```elixir
def deps do
  [{:vfs, "~> 0.1"}]
end
```

## Documentation

Hex docs: <https://hexdocs.pm/vfs>. Run `mix docs` to build locally.

## Development

```sh
mix setup     # deps + dialyzer PLT
mix check     # format, compile -W, credo, dialyzer, 100% coverage
mix test      # fast loop
```

`mix check` is the gate. It runs every commit, locally and in CI.

## License

MIT.
