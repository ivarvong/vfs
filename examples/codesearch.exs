# A real-network code-search workload: clone an actual GitHub repo via
# `:exgit` (HTTPS smart protocol), mount it through `:vfs`, walk every
# file in the tree, grep for a pattern, report stats.
#
# This is the canonical agent-loop scenario the design was built for:
# the same `%VFS{}` value flows from clone → mount → walk → read,
# threading the lazy backend's cache forward at each step.
#
# Usage (from the project root):
#
#     MIX_ENV=test mix run examples/codesearch.exs
#
# Optional env vars:
#
#     CODESEARCH_REPO     URL to clone (default: this repo, ivarvong/vfs)
#     CODESEARCH_PATTERN  regex pattern (default: "defmodule")
#     CODESEARCH_LAZY     "true" to use lazy partial clone (default: full)

defmodule Codesearch do
  @moduledoc false

  alias VFS.Test.ExgitMount

  def run do
    url = System.get_env("CODESEARCH_REPO", "https://github.com/ivarvong/vfs.git")
    pattern_str = System.get_env("CODESEARCH_PATTERN", "defmodule")
    lazy? = System.get_env("CODESEARCH_LAZY", "false") == "true"

    pattern = Regex.compile!(pattern_str)

    IO.puts("repo:    #{url}")
    IO.puts("pattern: #{inspect(pattern)}")
    IO.puts("mode:    #{if lazy?, do: "lazy partial clone", else: "full clone"}")
    IO.puts("")

    {clone_us, repo} = clone(url, lazy?)
    IO.puts(format_phase("clone", clone_us))

    fs = VFS.new() |> VFS.mount("/repo", ExgitMount.new(repo))

    # In lazy mode, walk requires an eager repository — materialize is
    # the lever to convert in one shot. In full-clone mode, the repo is
    # already eager and materialize is a no-op.
    fs =
      if lazy? do
        {mat_us, primed} = time(fn -> materialize!(fs) end)
        IO.puts(format_phase("materialize", mat_us))
        primed
      else
        fs
      end

    {walk_us, files} = walk(fs)
    IO.puts(format_phase("walk", walk_us, "#{length(files)} files"))

    {grep_us, results} = grep(fs, files, pattern)

    total_matches = Enum.reduce(results, 0, fn {_, n}, acc -> acc + n end)
    files_with_matches = Enum.count(results, fn {_, n} -> n > 0 end)

    IO.puts(format_phase("grep", grep_us, "#{total_matches} matches in #{files_with_matches} files"))
    IO.puts("")

    IO.puts("top hits:")

    results
    |> Enum.filter(fn {_, n} -> n > 0 end)
    |> Enum.sort_by(fn {_, n} -> -n end)
    |> Enum.take(10)
    |> Enum.each(fn {path, n} -> IO.puts("  #{n |> Integer.to_string() |> String.pad_leading(4)}  #{path}") end)
  end

  # ── phases ────────────────────────────────────────────────────────────

  defp clone(url, false) do
    time(fn ->
      case Exgit.clone(url) do
        {:ok, repo} -> repo
        {:error, reason} -> abort("clone failed: #{inspect(reason)}")
      end
    end)
  end

  defp clone(url, true) do
    time(fn ->
      case Exgit.clone(url, lazy: true, filter: {:blob, :none}) do
        {:ok, repo} -> repo
        {:error, reason} -> abort("lazy clone failed: #{inspect(reason)}")
      end
    end)
  end

  defp walk(fs) do
    time(fn ->
      fs
      |> VFS.walk("/repo")
      |> Enum.map(&elem(&1, 0))
    end)
  end

  defp materialize!(fs) do
    case VFS.materialize(fs) do
      {:ok, fs} -> fs
      {:error, reason} -> abort("materialize failed: #{inspect(reason)}")
    end
  end

  # Sequential per-file grep, threading state across reads so any cache
  # populated by the first read is visible to subsequent ones.
  defp grep(fs, files, pattern) do
    time(fn ->
      {results, _fs} =
        Enum.reduce(files, {[], fs}, fn path, {acc, fs} ->
          {n, fs} = count_matches(fs, path, pattern)
          {[{path, n} | acc], fs}
        end)

      Enum.reverse(results)
    end)
  end

  defp count_matches(fs, path, pattern) do
    case VFS.read_file(fs, path) do
      {:ok, content, fs} ->
        n = content |> String.split("\n") |> Enum.count(&Regex.match?(pattern, &1))
        {n, fs}

      {:error, _err} ->
        {0, fs}
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────

  defp time(fun) do
    start = System.monotonic_time(:microsecond)
    result = fun.()
    {System.monotonic_time(:microsecond) - start, result}
  end

  defp format_phase(label, us), do: format_phase(label, us, "")

  defp format_phase(label, us, extra) do
    ms = us / 1000
    line = "  #{String.pad_trailing(label <> ":", 14)} #{:erlang.float_to_binary(ms, decimals: 1) |> String.pad_leading(8)} ms"
    if extra == "", do: line, else: line <> "   #{extra}"
  end

  defp abort(msg) do
    IO.puts(:stderr, msg)
    System.halt(1)
  end
end

Codesearch.run()
