defmodule Mix.Tasks.Vfs.Mutate do
  @moduledoc """
  Light-weight mutation testing for the `:vfs` library.

  Iterates over every source file in `lib/`, applies one mutation at a
  time from a curated rule set, runs the test suite, and reports which
  mutations *survived* (tests still passed). Surviving mutations indicate
  weak spots in the test suite — code paths that ran but weren't actually
  verified.

  This is intentionally simpler than a full mutation framework. The curated
  rules target the kinds of mutations that catch real assertion gaps:

    * `>=` ↔ `>`, `<=` ↔ `<` — boundary off-by-one
    * `==` ↔ `!=`, `!=` ↔ `==` — equality logic
    * `&&` ↔ `||`, `and` ↔ `or` — boolean composition
    * `true` ↔ `false` — guard inversion

  ## Usage

      mix vfs.mutate                   # full report
      mix vfs.mutate --file lib/vfs.ex # single file
      mix vfs.mutate --quiet           # only print survivors

  ## Output

  Reports total mutations, killed (test failed), survived (test passed),
  and the kill rate. Aim for >85% on a healthy suite. Surviving mutations
  print file:line and the diff so you can write the missing assertion.

  ## Caveat

  Mutations are text-based, not AST-based. They may apply inside strings,
  comments, or doctests. Such mutations should still be killed by tests
  if the code in question is exercised; ones that survive in `@doc`
  strings can be rewritten to dodge the rule (e.g. `>=` in prose).
  """
  use Mix.Task

  @shortdoc "Run mutation testing against the vfs lib/ tree"

  @rules [
    {~r/(\s)>=(\s)/, ~S"\1>\2", ">= → >"},
    {~r/(\s)<=(\s)/, ~S"\1<\2", "<= → <"},
    {~r/(\s)>(\s)/, ~S"\1>=\2", "> → >="},
    {~r/(\s)<(\s)/, ~S"\1<=\2", "< → <="},
    {~r/(\s)==(\s)/, ~S"\1!=\2", "== → !="},
    {~r/(\s)!=(\s)/, ~S"\1==\2", "!= → =="},
    {~r/(\s)&&(\s)/, ~S"\1||\2", "&& → ||"},
    {~r/(\s)\|\|(\s)/, ~S"\1&&\2", "|| → &&"},
    {~r/(\s)and(\s)/, ~S"\1or\2", "and → or"},
    {~r/(\s)or(\s)/, ~S"\1and\2", "or → and"}
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [file: :string, quiet: :boolean],
        aliases: [f: :file, q: :quiet]
      )

    files = files_to_mutate(opts[:file])
    quiet? = opts[:quiet] || false

    Mix.shell().info("Running mutation testing on #{length(files)} file(s).")
    Mix.shell().info("(Each mutation runs the test suite; this takes a while.)\n")

    {killed, survived, mutations} =
      Enum.reduce(files, {0, 0, []}, fn file, {k, s, m} ->
        run_file(file, quiet?, k, s, m)
      end)

    print_summary(killed, survived, mutations, quiet?)
  end

  defp files_to_mutate(nil) do
    # Exclude the mutator's own task file from the default sweep — tests
    # don't cover Mix tasks the same way they cover library code, and
    # mutating the tool that's running the mutation is silly.
    "lib/**/*.ex"
    |> Path.wildcard()
    |> Enum.reject(&String.starts_with?(&1, "lib/mix/"))
  end

  defp files_to_mutate(file), do: [file]

  defp run_file(file, quiet?, killed, survived, mutations) do
    original = File.read!(file)
    candidates = generate_mutations(original)

    if not quiet?, do: Mix.shell().info("[#{file}] #{length(candidates)} candidate mutations")

    Enum.reduce(candidates, {killed, survived, mutations}, fn {mutated, line, label}, {k, s, m} ->
      File.write!(file, mutated)
      result = run_tests()
      File.write!(file, original)

      case result do
        :killed ->
          if not quiet?, do: Mix.shell().info("  killed:   line #{line}  #{label}")
          {k + 1, s, m}

        :survived ->
          Mix.shell().info("  SURVIVED: #{file}:#{line}  #{label}")
          {k, s + 1, [{file, line, label} | m]}
      end
    end)
  end

  defp generate_mutations(source) do
    lines = String.split(source, "\n")
    protected = protected_lines(lines)

    @rules
    |> Enum.flat_map(fn {regex, replacement, label} ->
      lines
      |> Enum.with_index(1)
      |> Enum.reject(fn {_, idx} -> MapSet.member?(protected, idx) end)
      |> Enum.flat_map(fn {line, idx} ->
        if Regex.match?(regex, line) do
          mutated_line = Regex.replace(regex, line, replacement, global: false)
          mutated = lines |> List.replace_at(idx - 1, mutated_line) |> Enum.join("\n")
          [{mutated, idx, label}]
        else
          []
        end
      end)
    end)
  end

  # Lines we should NOT mutate: those inside heredoc strings, single-line
  # docstrings (`@doc "..."`, `@typedoc "..."`, `@moduledoc "..."`), and
  # comment-only lines. Mutations there are guaranteed to "survive"
  # because they don't change runtime behavior.
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

  defp run_tests do
    # `mix test --no-cover --max-failures 1 --max-cases 1` for speed.
    # Recompile silently first to ensure the mutated source is picked up.
    {_, exit_code} =
      System.cmd("mix", ["test", "--no-cover", "--max-failures", "1"],
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    if exit_code == 0, do: :survived, else: :killed
  end

  defp print_summary(killed, survived, mutations, _quiet?) do
    total = killed + survived
    rate = if total == 0, do: 100.0, else: killed / total * 100

    Mix.shell().info("""

    ─────── mutation testing summary ───────
      total:    #{total}
      killed:   #{killed}
      survived: #{survived}
      kill rate: #{:erlang.float_to_binary(rate, decimals: 1)}%
    """)

    if survived > 0 do
      Mix.shell().info("Surviving mutations (test gaps):\n")

      mutations
      |> Enum.reverse()
      |> Enum.each(fn {file, line, label} ->
        Mix.shell().info("  #{file}:#{line}  #{label}")
      end)

      exit({:shutdown, 1})
    end
  end
end
