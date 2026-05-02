defmodule Mix.Tasks.Vfs.Audit do
  @moduledoc """
  Static performance audit for `:vfs`. Greps the `lib/` tree for known
  Elixir performance anti-patterns and reports findings with line
  numbers and a brief description.

  This is intentionally **regex-based, not AST-based.** It catches the
  high-leverage patterns (`++` on lists, `length/1` on lists in hot
  paths, `Enum.member?/2` on lists, `Map.size/1` instead of `map_size/1`,
  `Enum.into/2` chains that could be reduces) without becoming a
  full-fledged linter. False positives are expected and easy to spot;
  every finding is a "look here" prompt for human judgment, not a hard
  failure.

  Runs with **non-zero exit code** if any HIGH-severity findings remain.
  LOW/MEDIUM findings are informational.

  ## Usage

      mix vfs.audit                      # full audit
      mix vfs.audit --file lib/vfs.ex    # single file
      mix vfs.audit --severity low       # include LOW findings (default: hide)

  ## Severity levels

  * **HIGH** — almost always wrong in a hot path (`Map.size/1` instead
    of `map_size/1`, repeated `<>` concat in a reduce, `Enum.member?` on
    a list with thousands of elements).
  * **MEDIUM** — depends on context (`++` between two unbounded lists,
    `length/1` on a list whose length isn't known to be small).
  * **LOW** — pattern-matched concerns (`String.contains?` in a tight
    loop) that are usually fine but worth flagging.
  """
  use Mix.Task

  @shortdoc "Run static performance audit"

  @rules [
    # ── HIGH: almost always wrong ──
    {~r/\bMap\.size\(/, :high,
     "use `map_size/1` (BIF, O(1)) instead of `Map.size/1` (Elixir wrapper)"},
    {~r/\bKernel\.length\(/, :high, "use `length/1` directly, not `Kernel.length/1`"},
    {~r/Map\.keys\([^)]+\)\s*\|>\s*length/, :high,
     "`Map.keys |> length` allocates the keys list; use `map_size/1`"},

    # ── MEDIUM: depends on context ──
    {~r/(?<![\w.])\+\+\s/, :medium,
     "`++` is O(length(left)); ensure left list is small. See lib/vfs.ex `merge_entries` for an annotated example."},
    {~r/\bEnum\.member\?\(/, :medium,
     "`Enum.member?/2` is O(n) on lists; use a `MapSet`/`Map` for repeated membership checks"},
    {~r/\bEnum\.reverse\(/, :medium,
     "if you're reversing inside a reduce, prefer `:lists.reverse/1` (BIF, identical semantics, faster)"},
    {~r/\bEnum\.uniq\([^)]+\)\s*\|>\s*Enum\.sort/, :medium,
     "`Enum.uniq |> Enum.sort` does two passes; consider `Enum.sort |> Enum.dedup`"},

    # ── LOW: usually fine but worth flagging ──
    {~r/\bEnum\.find\([^,]+,\s*&\(&1\s*==/, :low,
     "`Enum.find(list, &(&1 == x))` is `Enum.member?` in disguise; a `Map`/`MapSet` is faster"},
    {~r/<<>>\s*<>\s*/, :low,
     "binary concat starting from `<<>>` — consider `IO.iodata_to_binary/1`"}
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [file: :string, severity: :string],
        aliases: [f: :file, s: :severity]
      )

    min_severity = parse_severity(opts[:severity] || "medium")
    files = files_to_audit(opts[:file])

    findings = Enum.flat_map(files, &audit_file/1)
    relevant = Enum.filter(findings, fn {_, _, sev, _} -> rank(sev) >= rank(min_severity) end)

    print_findings(relevant)
    print_summary(findings)

    if Enum.any?(relevant, fn {_, _, sev, _} -> sev == :high end), do: exit({:shutdown, 1})
  end

  defp files_to_audit(nil) do
    "lib/**/*.ex"
    |> Path.wildcard()
    |> Enum.reject(&String.starts_with?(&1, "lib/mix/"))
  end

  defp files_to_audit(file), do: [file]

  defp audit_file(file) do
    lines = File.read!(file) |> String.split("\n")
    protected = protected_lines(lines)
    suppressed_lines = suppressed_set(lines)

    @rules
    |> Enum.flat_map(fn {regex, severity, message} ->
      lines
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, idx} ->
        cond do
          MapSet.member?(protected, idx) -> []
          MapSet.member?(suppressed_lines, idx) -> []
          not Regex.match?(regex, line) -> []
          true -> [{file, idx, severity, message}]
        end
      end)
    end)
  end

  # A line containing `# vfs:audit-ok` (with anything after, typically a
  # short justification) suppresses the audit. Mix format may relocate
  # trailing comments above their statement, so we suppress both the
  # comment line itself AND the following non-blank line. Use sparingly
  # and always with a justification:
  #     # vfs:audit-ok — children bounded by branching factor
  #     new_queue = children ++ rest
  defp suppressed_set(lines) do
    lines
    |> Enum.with_index(1)
    |> Enum.reduce(MapSet.new(), fn {line, idx}, acc ->
      if String.contains?(line, "vfs:audit-ok") do
        acc |> MapSet.put(idx) |> MapSet.put(idx + 1)
      else
        acc
      end
    end)
  end

  @docstring_directive ~r/^\s*@(doc|moduledoc|typedoc|deprecated)\s/
  defp protected_lines(lines) do
    {protected, _} =
      lines
      |> Enum.with_index(1)
      |> Enum.reduce({MapSet.new(), false}, fn {line, idx}, {acc, in_heredoc?} ->
        triple_quote? = String.contains?(line, ~s("""))
        stripped = String.trim_leading(line)

        cond do
          in_heredoc? and triple_quote? -> {MapSet.put(acc, idx), false}
          not in_heredoc? and triple_quote? -> {MapSet.put(acc, idx), true}
          in_heredoc? -> {MapSet.put(acc, idx), true}
          String.starts_with?(stripped, "#") -> {MapSet.put(acc, idx), false}
          Regex.match?(@docstring_directive, line) -> {MapSet.put(acc, idx), false}
          true -> {acc, false}
        end
      end)

    protected
  end

  defp print_findings([]) do
    Mix.shell().info("No findings at the requested severity. Looks clean.\n")
  end

  defp print_findings(findings) do
    Mix.shell().info("\n─────── findings ───────\n")

    findings
    |> Enum.sort_by(fn {file, line, sev, _} -> {-rank(sev), file, line} end)
    |> Enum.each(fn {file, line, sev, message} ->
      Mix.shell().info("  [#{format_severity(sev)}] #{file}:#{line}\n      #{message}\n")
    end)
  end

  defp print_summary(findings) do
    counts = Enum.frequencies_by(findings, fn {_, _, sev, _} -> sev end)
    high = Map.get(counts, :high, 0)
    medium = Map.get(counts, :medium, 0)
    low = Map.get(counts, :low, 0)

    Mix.shell().info("─────── summary ───────")
    Mix.shell().info("  HIGH:   #{high}")
    Mix.shell().info("  MEDIUM: #{medium}")
    Mix.shell().info("  LOW:    #{low}")
    Mix.shell().info("  total:  #{high + medium + low}")
  end

  defp parse_severity("high"), do: :high
  defp parse_severity("medium"), do: :medium
  defp parse_severity("low"), do: :low
  defp parse_severity(other), do: Mix.raise("unknown severity: #{other}")

  defp rank(:low), do: 1
  defp rank(:medium), do: 2
  defp rank(:high), do: 3

  defp format_severity(:low), do: "LOW   "
  defp format_severity(:medium), do: "MEDIUM"
  defp format_severity(:high), do: "HIGH  "
end
