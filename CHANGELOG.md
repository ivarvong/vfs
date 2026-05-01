# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

While the library is pre-1.0, breaking changes may land in minor versions; they
will always be flagged here.

## [Unreleased]

### Added
- `VFS.Mountable` protocol — pluggable virtual filesystem with state-threading reads.
- `VFS.Stat`, `VFS.Path` foundation modules.
- `VFS.Memory` in-memory backend.
- `%VFS{}` mount table with longest-prefix routing; itself a `VFS.Mountable`.
- `VFS.Skeleton` macro for backend authors; `VFS.Default` fallback walk impl.
- `VFS.grep/4`, `VFS.glob/3` helpers composed from `walk` + `stream_read`.
- Telemetry events under the `[:vfs, _, _]` prefix for every public op.
- Conformance test harness parametrized over backend impls.
