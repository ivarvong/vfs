# Benchmark baselines

Reference numbers from `mix run bench/*.exs`, captured on:

- **Hardware:** Apple M3 Max, 16 cores, 48 GB RAM
- **Toolchain:** Elixir 1.20.0-rc.3, Erlang/OTP 28.4, JIT enabled
- **Date:** 2026-05-02

These are the baseline against which to detect performance regressions.
A 2x slowdown in any of the headline numbers should be investigated.

Run all five with:

```sh
mix run bench/path.exs
mix run bench/memory_io.exs
mix run bench/walk.exs
mix run bench/mount_dispatch.exs
MIX_ENV=test mix run bench/lazy_cache.exs   # uses GitFake from test/support/
```

## `VFS.Path.normalize/1` — every public op normalizes; this is the hot path

| Input              | ips     | median   | 99th    |
|--------------------|---------|----------|---------|
| `/`                | 4.25 M  | 208 ns   | 333 ns  |
| `/foo`             | 3.59 M  | 250 ns   | 375 ns  |
| `/a/b/c/d/e`       | 2.19 M  | 416 ns   | 583 ns  |
| 20-segment path    | 993 K   | 960 ns   | 1.4 µs  |
| `/a/./b/../c/d/e`  | 2.13 M  | 417 ns   | 584 ns  |
| Many redundancies  | 1.70 M  | 541 ns   | 709 ns  |

**Takeaway:** ~250 ns–1 µs per call. Negligible at any reasonable agent-loop call rate.

## `VFS.Memory` I/O — read/write throughput

| Op                                | 1 KB     | 64 KB    | 1 MB      |
|-----------------------------------|----------|----------|-----------|
| `read_file` (eager Memory override) | 349 ns | 354 ns | 570 ns  |
| `stream_read` + iodata collect    | 393 ns   | 392 ns   | 17.7 µs   |
| `write_file` (overwrite)          | 989 ns   | 972 ns   | 1.49 µs   |

**Takeaways:**

- Memory's `read_file/2` override returns the binary directly, so it's
  ~constant-time regardless of size. Use it when you want the full
  content; it's 30x faster than `stream_read`-then-collect for 1 MB.
- `stream_read` at default 64 KB chunks is the right choice for large
  files where you want to process incrementally — 17.7 µs for 1 MB is
  bandwidth-bound (~56 GB/s effective).
- Writes allocate ~1 KB regardless of payload size (Map.put + mtime
  update); the payload itself is shared via reference.

## `walk/3` — tree enumeration throughput

Tree shape: 100 buckets each holding 1/N of the files (depth 2).

| Files    | walk + Enum.count | walk + map + sort | through mount table |
|----------|-------------------|-------------------|---------------------|
| 100      | 1.04 ms           | 1.04 ms           | 1.13 ms             |
| 1,000    | 7.17 ms           | 7.30 ms           | 7.64 ms             |
| 10,000   | 76.9 ms           | 82.0 ms           | 80.9 ms             |

**Takeaways:**

- ~7-8 µs per file emitted, dominated by per-step `stat` + `readdir`
  protocol dispatch and `Stream.resource` overhead. Linear scaling —
  no quadratic blowup.
- Mount-table dispatch adds ~5-9% — small but measurable.
- `Enum.sort` on 10k items costs ~5 ms (the difference between count and
  map+sort).

## Mount-table dispatch overhead

Single op (`read_file`):

| Backend                                       | ips      | average  |
|-----------------------------------------------|----------|----------|
| Direct backend (`VFS.Memory`)                 | 2.95 M   | 339 ns   |
| Mount table (1 mount at `/`)                  | 786 K    | 1.27 µs  |
| Mount table (1 mount at `/sub/deep/repo`)     | 487 K    | 2.05 µs  |
| Mount table (10 mounts, longest-prefix match) | 468 K    | 2.14 µs  |

**Takeaways:**

- Mount-table tax: ~1-2 µs per op (path normalize + resolve + repack).
- Going from 1 to 10 mounts adds only ~90 ns: longest-prefix matching
  is essentially free. We can mount aggressively.
- If you need maximum throughput, call the backend's `defimpl` directly
  and skip the mount table.

## Lazy cache (`VFS.Test.GitFake`) — hit/miss cost

In GitFake, the "remote" is an in-memory map, so miss vs hit costs are
nearly identical. The benchmark isolates **protocol-level overhead per
read**; in a real exgit defimpl with network fetches, miss cost would
be dominated by I/O — making `materialize/2` valuable.

| Scenario                               | ips     | average  |
|----------------------------------------|---------|----------|
| Cold miss (cache empty)                | 1.45 M  | 692 ns   |
| Warm hit (cache pre-populated)         | 1.38 M  | 726 ns   |
| Miss → hit sequential, state threaded  | 0.77 M  | 1.30 µs  |

Memory: cold miss allocates ~24 B more than warm hit (the cache entry).

## Notable absences

These would matter for shipping but aren't measured yet:

- **Concurrent walk over a single FS** — the lib is pure, every fs is
  immutable, so any number of processes can hold the same `%VFS{}` and
  read concurrently. No measurements yet but no race-condition surface
  either; benchmark left as v0.2 work.
- **Real-world directory traversal patterns** — our walk benchmark uses
  a synthetic shape. A snapshot of an actual repo (e.g. once `:exgit`
  lands) would surface real distributions of branching factor and depth.
- **Latency under a hostile telemetry handler** — every public op spans
  through `:telemetry.span/3`. A handler that does heavy work in-process
  would slow every op. Currently un-benchmarked.
