# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

While the library is pre-1.0, breaking changes may land in minor versions; they
will always be flagged here.

## [Unreleased]

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
