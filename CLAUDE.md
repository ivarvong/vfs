# `vfs` — Claude operating notes

This is a protocol-based virtual filesystem library for the Elixir AI tools stack. **Read `SPEC.md` for the full design and rationale** — every architectural decision (and most non-decisions) lives there. This file is the operating manual: the small set of rules that are easy to get wrong, plus the bar we hold ourselves to.

The library is foundational — `just_bash`, `pyex`, and any future agent tool will depend on it, and an FS state object will be threaded between them across a single agent loop. It needs to be diamond-quality. Optimize for correctness, narrow API surface, and test rigor over feature breadth.

---

## Naming

- The module is `VFS`. Acronym stays **uppercase everywhere**: `VFS`, `VFS.Mountable`, `VFS.Memory`, `VFS.Stat`. **Never `Vfs`.** Matches the `JustBash.FS` precedent (commit `6250b8f`, "uppercase FS acronym in new module names").
- The `mix new` skeleton currently uses `Vfs` and a `hello/0` placeholder — fix on the first real edit.
- Hex package `:vfs`, repo `ivarvong/vfs`.

## The non-negotiable invariant: state threads back through every op

**Every `VFS.Mountable` operation returns the (possibly updated) impl as the last element of its success tuple. Reads included.**

```elixir
{:ok, bin, impl}    = VFS.Mountable.read_file(impl, path)
{:ok, stream, impl} = VFS.Mountable.stream_read(impl, path, opts)
{:ok, stat, impl}   = VFS.Mountable.stat(impl, path)
{exists?, impl}     = VFS.Mountable.exists?(impl, path)
```

Lazy backends (e.g. an exgit-backed mount that fetches blobs on demand) populate caches inside their struct on read. Throwing the returned impl away destroys the cache — this was the single biggest defect in the prior `JustBash.FS.Backend` behaviour. Every caller threads state forward; the mount-table defimpl threads it back into the right mount slot. If you see code that pattern-matches a protocol op as a 2-tuple `{:ok, x}`, that is a bug.

The one exception is `walk/3`, which returns a bare `Enumerable.t()` — cache state populated *during* enumeration does not escape (see SPEC §"The cache-eviction caveat"). For agent loops that re-touch the same files after a walk, call `materialize/2` first.

## Path contract

All paths reaching a backend impl are:

- absolute,
- already normalized (no `.`/`..`/double slashes),
- leading `/`.

Mount-prefix stripping happens in `VFS`'s defimpl **before** the call reaches a backend. A backend impl should never see a path containing its own mountpoint. Path normalization is centralized in `VFS.Path`; do not reinvent it elsewhere.

## Errors are structured `%VFS.Error{}` exceptions

Every fallible protocol op returns `{:ok, ...} | {:error, %VFS.Error{}}`. The struct has four fields: `:kind` (a POSIX-style atom), `:path` (the path that failed, in the user's view), `:mount` (the mountpoint that handled it, attached by the dispatcher), and `:message` (human-readable, defaulted from kind+path).

Pattern-match on `:kind` for control flow. `:kind` is one of:

| Kind | When |
|---|---|
| `:enoent` | path doesn't exist |
| `:eexist` | path already exists (e.g. `mkdir` collision) |
| `:eisdir` | expected a file, got a directory |
| `:enotdir` | expected a directory, got a file |
| `:erofs` | the **mount or wrapper** is read-only |
| `:enotsup` | the **backend** doesn't implement this op |
| `:eacces` | permission denied |
| `:einval` | bad argument (e.g. malformed path or option) |
| `:exdev` | cross-mount op that can't be atomic |
| `:eio` | underlying I/O failure |
| `:eloop` | symlink loop |

`:erofs` vs `:enotsup` is a real distinction: a read-only-wrapping defimpl refuses writes with `:erofs`; a backend that simply doesn't implement an op returns `:enotsup`. Pyex's old "format Python error string in the FS layer" pattern is wrong — error formatting belongs at the consumer boundary, not in vfs. Errors are also raisable (`raise VFS.Error, kind: ..., path: ...`) for `!`-style helpers.

## `%VFS.Stat{}`, not `File.Stat`

Exactly four fields:

- `type :: :regular | :directory | :symlink | :other` — atom, mirrors stdlib `File.Stat`. **Never** add `is_file`/`is_directory` booleans.
- `mtime :: DateTime.t()` — not Erlang datetime tuples. New abstraction, no legacy burden.
- `mode :: non_neg_integer() | nil` — explicitly nullable; S3 has no meaningful mode.
- `size :: non_neg_integer()` — bytes for files; backends usually return 0 for directories.

Don't grow this struct. Backend-specific metadata (blob SHA, S3 ETag, etc.) is exposed via backend-module getters, never through the universal stat shape.

## `readdir/2` returns `Enumerable.t(String.t())`, not necessarily a list

Bounded backends (Memory, future SQLite-backed, etc.) should return a list of names — the simplest Enumerable, supports `length/1` and `Enum.sort/1` natively. Unbounded or paginated backends (S3 with millions of keys, a virtual `/integers/N` namespace, a database cursor) should return a `Stream`. Consumers must treat the result as Enumerable: use `Enum.to_list/1` only when you know it's bounded; use `Stream.take/2` when you don't.

The mount-table dispatcher detects list-vs-stream and merges synthetic mountpoint children appropriately — sorted+deduped for bounded, concat-with-synthetic-prepended for unbounded.

This is the design that lets vfs front a real S3 or git backend with realistically-sized listings without exploding memory. See `test/support/lazy_dir.ex` for a worked example.

## Read API: `stream_read/3` is primary, `read_file/2` is derived

The `VFS.Skeleton` macro supplies a default `read_file/2` that runs `stream_read` into a binary via `IO.iodata_to_binary`. New backends implement `stream_read/3` and let the skeleton derive the rest. Override `read_file/2` only when there's a measurably faster eager path (e.g. `VFS.Memory`, where the bytes are already in hand).

If you ever materialize a binary to then re-stream it, you're doing it backwards.

## Keep the protocol minimal — the bar for new ops is high

The v0.1 protocol surface is **9 callbacks**: `exists?`, `stat`, `readdir`, `stream_read`, `walk`, `write_file`, `mkdir`, `rm`, `materialize`, `capabilities`.

A new protocol op is justified only when:

1. It cannot be expressed efficiently in terms of the existing callbacks, **and**
2. Multiple backend types could meaningfully implement it differently (i.e. pushdown matters).

Things that are explicitly **not** protocol ops:

- `read_file` — derived in `VFS.read_file/2` from `stream_read/3`. Backends that have an eager fast path can return a single-chunk stream from `stream_read`.
- `grep`, `glob`, `find`, `cp`, `mv` — out of the core. Either consumer code or a future companion package. The library is a filesystem abstraction; search and composition are layers above.
- `lstat`, `readlink`, `symlink`, `link` — no v1 backend uses these. Add when there's a real consumer.
- `chmod` — no real consumer yet. Memory tracks modes internally if needed; lift to a separate `VFS.Permissioned` protocol if a future backend cares.
- `append_file` — composable from `read_file + write_file` at the consumer.
- `hash`, `diff` — deferred to optional secondary protocols if patterns recur.
- `%VFS.Match{}` or any op-specific result struct — plain tuples in consumer code; named types are a consumer-side concern.

Backend-specific perf optimizations (e.g. an exgit pack-internal scanner) live in the backend module, **not** the core protocol. The protocol provides correctness and portability; the backend module provides peak perf when a caller can commit to a specific backend. This is the "escape hatch" pattern; it is not a leak.

## Capabilities

`capabilities/1` returns `MapSet.t(atom)`. Documented atoms: `:read`, `:write`, `:native_walk`, `:native_stream_read`, `:lazy`. Don't introduce new ones without a concrete consumer that needs to branch on them.

## Observability — `:telemetry` events, OTel-ready

VFS is a hot-path dep in agent loops. Observability is non-optional. Every public op in the `VFS` module is wrapped in `:telemetry.span/3` so consumers can attach OpenTelemetry handlers, log handlers, metric handlers without us caring how.

**Event taxonomy** — `[:vfs, <op>, :start | :stop | :exception]` for every public op. Stable contract; treat additions like a SemVer-bumping API change.

| Event prefix | Metadata (start) | Measurements (stop) |
|---|---|---|
| `[:vfs, :read_file, _]` | `%{path, impl}` | `%{duration, bytes}` |
| `[:vfs, :stream_read, _]` | `%{path, impl, opts}` | `%{duration}` (open only; per-chunk not emitted) |
| `[:vfs, :write_file, _]` | `%{path, impl, bytes}` | `%{duration}` |
| `[:vfs, :mkdir, _]` | `%{path, impl, opts}` | `%{duration}` |
| `[:vfs, :rm, _]` | `%{path, impl, opts}` | `%{duration}` |
| `[:vfs, :walk, _]` | `%{root, impl, opts}` | `%{duration, entries}` (terminal — emitted on enumeration end) |
| `[:vfs, :materialize, _]` | `%{impl}` | `%{duration}` |
| `[:vfs, :cache, :hit]` / `[:vfs, :cache, :miss]` | `%{path, impl}` | `%{}` |

On error the `:stop` event metadata also includes `%{error: %VFS.Error{...}}`.

Rules:

- Telemetry calls live in the **`VFS` public-module helpers**, not in protocol impls. Wrapping at the helper layer means every consumer gets instrumentation for free, the protocol stays clean, and impls don't have to remember to emit. The one exception is `[:vfs, :cache, :hit | :miss]` — those are emitted by lazy backends themselves, since only they know.
- `metadata.impl` carries the impl module (`impl.__struct__`), not the full struct. Cheap, sufficient for grouping in dashboards.
- Treat the event names and metadata keys as a public contract. Renaming an event is a breaking change.
- The conformance suite asserts every helper emits the right `:start`/`:stop` (or `:exception`) pair via a test handler that forwards to `self()`. Drift is caught immediately.
- We ship a `vfs_otel` companion package later if we want a turnkey OTel bridge, but the primary library stays at the `:telemetry` layer — every Elixir consumer already has telemetry handlers in their toolbox.

## Dependencies

- **Runtime deps:** `:telemetry` only. It is universally treated as effectively-stdlib in the Elixir ecosystem (Phoenix, Ecto, Broadway, Oban all depend on it) and is the seam that makes OTel integration work. **No other runtime deps without explicit discussion.** This is load-bearing: vfs is a *pure library* — no `Application`, no `start_link`, no global ETS, no init-on-load. The user-visible state is exactly what they hold in their hand. That property is *why* this can be passed across an agent loop, run inside a release, on Nerves, or in a test sandbox without ceremony.
- **Dev/test deps:** `:stream_data`, `:dialyxir`, `:credo`, `:excoveralls`, `:ex_doc`, `:benchee` (optional perf tracking).
- Backend libraries (`:exgit`, future S3 impl, etc.) take `:vfs` as an **optional** dep — never the reverse. Dependency direction is backend → vfs. Per Dave: vfs is the abstraction, exgit is the concrete thing.

## Code quality bar

- `@spec` on every public function (including all protocol callbacks and `VFS` helpers). Specs match the protocol contract exactly — no quietly-relaxed return shapes.
- `@moduledoc` on every public module. No `@moduledoc false` on a public surface.
- `@doc` plus at least one example (ideally a doctest) on every public function.
- `@type t` for every public struct, with `@enforce_keys` where missing fields would be a bug.
- Use parametric type specs everywhere (`MapSet.t(atom)`, `Enumerable.t(binary)`), never the bare unparameterized form. Set-theoretic types in 1.18+ catch real bugs from these.
- Comments are for the *why*, never the *what*. Acceptable forms: invariants, hidden constraints, references to spec sections (`# See SPEC.md §"cache-eviction caveat"`). Self-describing identifiers carry the *what*.
- No premature abstractions. Three similar lines beat a wrong abstraction. Don't build `VFS.Foo` until two callers actually need it.
- Pattern-match in function heads to express the contract — prefer `def stream_read(%VFS.Memory{} = mem, path, opts)` over `case impl.__struct__` in the body.
- Idiomatic Elixir baseline: `Stream.resource/3` for `walk`; `Task.async_stream/3` for parallel ops; `IO.iodata_to_binary/1` (canonical) for the iodata roll-up; pin operator (`^`) where it clarifies; no `String.to_atom/1` on dynamic input; no `try/rescue` for control flow.

## Testing bar

- **Coverage gate is 100% line, no exceptions.** ExCoveralls. Genuinely unreachable branches use a single-line `# coveralls-ignore-next-line` with a comment explaining why. CI fails the build if coverage drops below 100%. The library is small enough that the floor is achievable; "95% with handwave" is a slippery floor for a foundational dep.
- **Conformance suite as a `use`-able macro.** `VFS.ConformanceCase` parametrized on a `backend_factory`. Every backend (`VFS.Memory`, `%VFS{}` mount table, the test-only `LazyFake` in `test/support/`, downstream `defimpl`s in exgit/pyex) runs the *exact* same test set. Adding a backend = one parametrization, never duplicated tests. The harness is the contract.
- **Stateful property testing with `:stream_data`.** A small `VFS.Test.CommandDSL` generates random sequences of `{:write, path, bytes} | {:read, path} | {:rm, path} | {:walk, root}` actions; an interpreter runs them against both a reference model (`%{path => bytes}` map) and the impl under test, asserting observable behavior matches at every step. This is the technique most Elixir libs skip and pay for later — we don't skip it.
- **Plain property tests** for cross-cutting invariants:
  - path normalization is idempotent (`normalize(normalize(p)) == normalize(p)`) and always absolute,
  - `write_file` then `read_file` round-trips for any binary,
  - `walk` enumerates exactly the set produced by recursive `readdir`+`stat`,
  - state threaded back from any read sequence is itself a valid impl (re-readable),
  - capability claims match observed behavior (if `:write` ∉ caps → every mutation returns `:erofs` or `:enotsup`).
- **State threading is directly tested.** `VFS.Test.LazyFake` (in `test/support/`) is a backend whose struct counts cache hits/misses. A property test asserts: for any read sequence, threading state back yields strictly fewer misses than discarding it. This makes the central design invariant a checkable claim, not just docs.
- **Telemetry events are tested.** Every public-helper test attaches a forwarder handler and asserts the right `[:vfs, _, :start | :stop]` pair (or `:exception` for negative-path tests) was emitted with the expected metadata/measurements keys. Catches drift in the observability contract.
- **Doctests on every public function.** They are the primary usage docs and the first thing readers see on hex.pm.
- **`async: true` everywhere.** Backends are immutable structs; tests have no shared state.
- **No mocks for backends.** If you want one, you want a `VFS.Memory`. Backend conformance verifies against real impls; downstream backends run the conformance suite themselves against real fixtures.
- **Every error atom return path has a named test.** POSIX-atom drift is the most likely consumer-facing regression and the cheapest to gate on. The conformance suite walks an `errors_table/0` so adding a new error atom forces test coverage.
- **CI runs the suite twice** — once with `consolidate_protocols: true` (release-style), once off (dev-style). Catches consolidation-mode bugs that only show in releases.
- `consolidate_protocols: Mix.env() != :test` in `mix.exs`. Without it, test-only `defimpl`s aren't picked up across reloads.

## Toolchain & gates

**Versions:**

- **Elixir floor for users: `~> 1.18`** in `mix.exs` (the `elixir:` requirement). Set-theoretic types in compiler warnings, `mix format --migrate`, parametric type checking — all available from 1.18.
- **Local dev + CI run on the latest pre-release** (1.20-rc as of this writing). We deliberately ride the bleeding edge of the toolchain so new compiler warnings, type-inference checks, and `mix xref` capabilities surface here first. Anything 1.20-rc flags, we fix or pragma. The `mise.toml` / `.tool-versions` pins the rc; users on 1.18 still get a working library.
- CI matrix: `{1.18 stable, 1.20-rc}` × `{OTP latest two}`. The 1.18 leg confirms the floor still works; the 1.20-rc leg is the real gate.

**The `mix check` aggregator is the single command that gates every commit.** Defined as an alias in `mix.exs`:

```elixir
aliases: [
  check: [
    "format --check-formatted",
    "compile --warnings-as-errors",
    "credo",
    "dialyzer",
    "coveralls --raise"   # 100% gate; drops fail the build
  ]
]
```

- **`mix check` runs every time, before every commit and in CI.** That is non-negotiable. A pre-commit hook (`.git/hooks/pre-commit` calling `mix check`, set up via a `mix setup` alias) wires this locally. CI runs the same `mix check` — same command, same gates, no divergence.
- **Credo: default config, not `--strict`.** Strict trips on legitimate patterns in protocol-heavy libraries (e.g. nested `defimpl` blocks). A small `.credo.exs` documents any disabled checks with a one-line reason.
- **Dialyzer: warnings-as-errors with the strict flag set** — `flags: [:error_handling, :unknown, :unmatched_returns, :extra_return, :missing_return]`. PLT cached in CI keyed on `mix.lock`.
- **`elixirc_options: [warnings_as_errors: true]`** in `:prod` and `:test`. Type-system warnings from 1.18+/1.20-rc are bugs to fix, not noise to ignore.
- **`mix format --migrate`** is run as part of `format` to auto-upgrade deprecated forms.

## Useful commands

```sh
mix setup                  # deps.get + dialyzer PLT build + install pre-commit hook
mix check                  # the full gate: format, compile -W, credo, dialyzer, 100% coverage. RUN BEFORE EVERY COMMIT.
mix test                   # fast loop
mix test --cover           # local coverage check
mix test path/to/file_test.exs:42
mix coveralls.html         # detailed coverage report (open cover/excoveralls.html)
mix format                 # auto-fix + --migrate for deprecated forms
mix credo
mix dialyzer
mix docs                   # ex_doc — first sentence of @moduledoc lands on hex.pm, write it deliberately
mix vfs.mutate             # mutation testing — run periodically, NOT in mix check (slow)
mix vfs.mutate --file lib/vfs/memory.ex  # single file
mix vfs.audit              # static perf audit (regex-based; see lib/mix/tasks/vfs.audit.ex)
mix run bench/path.exs     # individual benchmarks; see bench/baselines.md
```

## Performance discipline

- **`mix vfs.audit`** flags known anti-patterns (`++` between unbounded
  lists, `length/1` in hot paths, `Map.size/1` instead of `map_size/1`,
  etc.). Mark intentional exceptions with a trailing `# vfs:audit-ok`
  pragma; always include a justification. Run before every commit.
- **`bench/baselines.md`** documents reference numbers on a known
  reference machine. A 2× regression from baseline on any headline
  metric (path normalization, mount dispatch, walk throughput) is a
  signal to investigate before merging.
- The mount-table tax is real (~1–2 µs/op). For tight inner loops where
  the mount is fixed, consider calling the backend's `defimpl` directly
  via `VFS.Mountable.read_file(backend, path)` instead of going through
  `VFS.read_file(mount_table, path)`.

## Mutation testing

We ship a custom `mix vfs.mutate` task (purposefully simple — text-based,
~150 lines). It applies one mutation at a time from a curated rule set
(`>=` ↔ `>`, `<=` ↔ `<`, `==` ↔ `!=`, `&&` ↔ `||`, `and` ↔ `or`, etc.),
runs the test suite, and reports survivors. Surviving mutations indicate
test gaps — code paths that ran but weren't actually verified.

Run periodically (not on every commit — it's ~1.5 min per file). Healthy
kill rate: **>90%** with no real-bug survivors. Current rate is 93%; the
3 remaining are a string-literal false positive and two equivalent
mutations (different code, same observable behavior).

Mutation testing is the cure for "100% line coverage but bugs slip
through" — the lines run, but no assertion catches the wrong answer.

## When in doubt

- Default to **no** for protocol changes. The surface is small on purpose.
- Default to **no** for new runtime deps, new `%VFS.Stat{}` fields, new error atoms, new capability atoms.
- SPEC.md is the source of truth; if it disagrees with code, the code is wrong (or the spec needs an explicit amendment first).
