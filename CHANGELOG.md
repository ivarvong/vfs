# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

While the library is pre-1.0, breaking changes may land in minor versions; they
will always be flagged here.

## [Unreleased]

## [0.1.0] - 2026-06-08

First public release.

### Audit (2026-05-02): four contract bugs found and fixed

A staff-level review surfaced four bugs that the existing 100%-coverage,
93%-mutation-kill-rate test suite missed because every test verified
"the code does what we wrote" rather than "the code matches the
published contract." Each is now a property in `test/vfs/contracts_test.exs`.

  - **walk leaked mount-shadowed paths.** When a longer-prefix mount
    overlaps a shorter one (e.g. `/` mount has `/a/old`, `/a` is mounted
    separately), `VFS.walk/3` emitted `/a/old` even though
    `VFS.read_file(fs, "/a/old")` returned `:enoent`. Walk now filters
    each emission against `VFS.__resolve__` to verify it routes back
    to the source mount; shadowed paths are dropped.

  - **Default walk eagerly consumed lazy `readdir`.** The protocol
    permits `readdir/2` to return an unbounded `Enumerable`. The old
    walker called `Enum.map` on the names, materializing the full
    stream before enqueuing children — making `walk |> Stream.take(N)`
    hang on backends like `LazyDir` whose readdir is infinite by design.
    Rewritten as recursive `Stream.flat_map` so the consumer's `take/2`
    bounds total work.

  - **`VFS.Memory.new/1` accepted contradictory seeds.** The constructor
    permitted seeds like `%{"/a" => "f", "/a/b" => "c"}` that produced
    state where `stat` reported `:regular` and `readdir` simultaneously
    treated the same path as a directory. Now validates: rejects `/`
    as a file key, rejects any pair of paths in a strict prefix
    relationship.

  - **`:line_range` accepted malformed `(first, last)` pairs.** `{2, 0}`,
    `{1, -1}`, `{3, 2}` slipped past validation and returned silent
    surprising slices. Critical for LLM tool boundaries that use line
    ranges to retrieve precise context windows: silent-wrong is worse
    than loud `:einval`. Now validates `last >= first AND last >= 1`
    when `last` is an integer.

### Changed

- Capabilities split: `:write` no longer implies `:mkdir`. Flat-keyed
  backends like `VFS.Test.AppService` (and future S3, postgres impls)
  declare `:write` without `:mkdir` since they don't model empty
  directories. Conformance suite gates `mkdir` tests on `:mkdir in caps`.

- Stream-option handling (`:chunk_size` / `:byte_range` / `:line_range`)
  extracted from `VFS.Memory` into the new public `VFS.StreamOptions`
  module. Every backend whose `stream_read/3` returns bytes now uses
  the same validated helper. Added because `VFS.Test.AppService`
  silently ignored those options before the audit caught it.

### Added

- `test/vfs/contracts_test.exs`: 17 property tests over the published
  protocol contract — observation consistency (stat/readdir/exists?/
  read_file agreement), write/read round-trip, rm+read agreement,
  materialize idempotence, byte_range and line_range validation,
  capabilities reflect behavior, adversarial inputs to constructors,
  walk = read-reachable namespace, walk + take terminates over
  unbounded readdir.

- `lib/vfs/stream_options.ex`: shared option handler for backend
  authors. ~150 lines, 100% covered by `test/vfs/stream_options_test.exs`.

- Conformance suite extended to `VFS.Test.AppService` (read+write,
  no mkdir) and `VFS.Test.LazyFake` (read-only).

### Numbers after the audit

  - 331 tests / 45 properties / 36 doctests / 0 failures across all scopes
  - 100% line coverage
  - 97.7% mutation kill rate (up from 93%)
  - `mix check` clean: format, compile -W, credo, dialyzer, coverage
  - `mix vfs.audit` clean: 0 high / 0 medium / 0 low findings

### Added
- `VFS.Mountable` protocol — pluggable virtual filesystem with state-threading reads.
- `VFS.Stat`, `VFS.Path`, `VFS.Error` foundation modules. Errors are
  structured `%VFS.Error{kind, path, mount, message}` exceptions; pattern
  match on `:kind` for control flow.
- `VFS.Memory` in-memory backend (read+write).
- `%VFS{}` mount table with longest-prefix routing; itself a `VFS.Mountable`.
- `VFS.Skeleton` macro for backend authors; `VFS.Default` fallback walk impl.
- `VFS.read_file/2` derived from `VFS.Mountable.stream_read/3`; honors
  `:chunk_size`, `:byte_range`, and `:line_range` options.
- Telemetry events under the `[:vfs, _, _]` prefix for every public op.
- `VFS.assert_implemented!/1` for validating values at trust boundaries.
- Conformance test harness (`VFS.ConformanceCase`) parametrized over backend impls.

[Unreleased]: https://github.com/ivarvong/vfs/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/ivarvong/vfs/releases/tag/v0.1.0
