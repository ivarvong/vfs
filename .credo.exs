%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: []
      },
      strict: false,
      color: true,
      checks: %{
        disabled: [
          # Protocol implementations naturally nest deeper than 2 levels (defprotocol -> defimpl -> def).
          # The check produces noise in a protocol-heavy codebase without catching real issues.
          {Credo.Check.Refactor.Nesting, []},
          # We have helper modules with one or two functions by design (e.g. VFS.Default).
          # The "module too small" lens doesn't fit a library that's deliberately fragmented for clarity.
          {Credo.Check.Readability.ModuleDoc, [ignore_names: [~r/^VFS\.Mountable\.[A-Z]/]]},
          # `:telemetry.execute/3` calls look like "atom dispatch is bad" to Credo, but it's the
          # canonical Erlang module call form for the telemetry library.
          {Credo.Check.Warning.UnsafeToAtom, []},
          # `VFS.ConformanceCase` is a macro that injects an entire shared test suite into
          # the host module. A long quote block is the whole point — splitting it would just
          # fragment the suite without making it more readable.
          {Credo.Check.Refactor.LongQuoteBlocks, []}
        ]
      }
    }
  ]
}
