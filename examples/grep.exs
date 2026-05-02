# A real-network *grep* over a GitHub repo: clone via `:exgit` (HTTPS),
# mount through `:vfs`, walk every file, count regex matches per file,
# report stats. The unstructured cousin of `examples/list_skills.exs`.
#
# This is grep, not codesearch — the output is line counts, not
# structured records. For *real* codesearch (parse front-matter, extract
# semantic structure, return queryable data), see `list_skills.exs`.
# Use this when you want a quick line count, not when you want answers.
#
# Usage:
#
#     MIX_ENV=test mix run examples/grep.exs
#
# Optional env vars:
#
#     CODESEARCH_REPO     URL to clone (default: this repo, ivarvong/vfs)
#     CODESEARCH_PATTERN  regex pattern (default: "defmodule")
#     CODESEARCH_MODE     one of: "shallow" (default — depth=1, just HEAD),
#                                 "full" (entire history),
#                                 "lazy" (partial; fetch blobs on demand
#                                 via materialize)

defmodule Codesearch do
  @moduledoc false

  alias VFS.Test.ExgitMount

  def run do
    url = System.get_env("CODESEARCH_REPO", "https://github.com/ivarvong/vfs.git")
    pattern_str = System.get_env("CODESEARCH_PATTERN", "defmodule")
    mode = parse_mode(System.get_env("CODESEARCH_MODE", "shallow"))

    pattern = Regex.compile!(pattern_str)

    IO.puts("repo:    #{url}")
    IO.puts("pattern: #{inspect(pattern)}")
    IO.puts("mode:    #{describe_mode(mode)}")
    IO.puts("")

    {clone_us, repo} = clone(url, mode)
    IO.puts(format_phase("clone", clone_us))

    fs = VFS.new() |> VFS.mount("/repo", ExgitMount.new(repo))

    # In `:lazy` mode the repo is in lazy partial-clone state — walk
    # requires it to be eager. `VFS.materialize` flips the mode and
    # batch-fetches every referenced blob in one shot. For `:full` and
    # `:shallow`, the repo is already eager and materialize is a no-op
    # (we skip the call rather than emit a useless 0-ms phase).
    fs =
      if mode == :lazy do
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

  defp parse_mode("shallow"), do: :shallow
  defp parse_mode("full"), do: :full
  defp parse_mode("lazy"), do: :lazy
  defp parse_mode(other), do: abort("unknown CODESEARCH_MODE: #{inspect(other)}")

  defp describe_mode(:shallow), do: "shallow clone (depth=1 — HEAD commit only, no history)"
  defp describe_mode(:full), do: "full clone (entire history)"
  defp describe_mode(:lazy), do: "lazy partial clone (fetch blobs on demand via materialize)"

  defp clone(url, :shallow) do
    time(fn ->
      case Exgit.clone(url, depth: 1) do
        {:ok, repo} -> repo
        {:error, reason} -> abort("shallow clone failed: #{inspect(reason)}")
      end
    end)
  end

  defp clone(url, :full) do
    time(fn ->
      case Exgit.clone(url) do
        {:ok, repo} -> repo
        {:error, reason} -> abort("full clone failed: #{inspect(reason)}")
      end
    end)
  end

  defp clone(url, :lazy) do
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
