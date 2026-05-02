# What this is
# ============
#
# A real codesearch query, not a grep wrapper. Answers the question:
#
#     "What are all the skills in this repo, and what does each one do?"
#
# Concretely: clone https://github.com/anthropics/skills (any GitHub repo
# really, but this one has a `SKILL.md` per skill), walk the tree, find
# every `SKILL.md`, parse its YAML front-matter, return structured records.
#
# Output is structured — name, description, path — not lines of text.
# An agent receiving this output can route to a specific skill by name,
# filter by topic, sort by relevance, or display them all to the user.
# That's the value over `grep`: the answer is data, not bytes.
#
# Run:
#
#     MIX_ENV=test mix run examples/list_skills.exs
#
# Optional:
#
#     LIST_SKILLS_REPO=https://github.com/some/other-repo.git \
#         MIX_ENV=test mix run examples/list_skills.exs
#
# The repo just needs to have `SKILL.md` files with YAML front-matter
# containing `name:` and `description:`.

defmodule ListSkills do
  @moduledoc false

  alias VFS.Test.ExgitMount

  defmodule Skill do
    @moduledoc false
    @enforce_keys [:name, :path]
    defstruct [:name, :description, :license, :path]
  end

  def run do
    url = System.get_env("LIST_SKILLS_REPO", "https://github.com/anthropics/skills.git")

    IO.puts("repo: #{url}\n")

    {clone_us, repo} = time(fn -> clone!(url) end)
    fs = VFS.new() |> VFS.mount("/repo", ExgitMount.new(repo))

    {query_us, skills} = time(fn -> list_skills(fs) end)

    IO.puts("found #{length(skills)} skills (clone #{ms(clone_us)}, query #{ms(query_us)})\n")

    skills
    |> Enum.sort_by(& &1.name)
    |> Enum.each(&print/1)
  end

  # ── the codesearch query ───────────────────────────────────────────────
  #
  # Walk the tree, filter to `SKILL.md` files, read each, parse front-matter,
  # build a structured record. State (the underlying mount/cache) threads
  # through every read so the dispatcher accumulates work cleanly.

  defp list_skills(fs) do
    skill_files =
      fs
      |> VFS.walk("/repo")
      |> Stream.map(&elem(&1, 0))
      |> Stream.filter(&String.ends_with?(&1, "/SKILL.md"))

    {skills, _fs} =
      Enum.reduce(skill_files, {[], fs}, fn path, {acc, fs} ->
        case parse_skill(fs, path) do
          {:ok, skill, fs} -> {[skill | acc], fs}
          {:skip, fs} -> {acc, fs}
        end
      end)

    Enum.reverse(skills)
  end

  defp parse_skill(fs, path) do
    case VFS.read_file(fs, path) do
      {:ok, content, fs} ->
        case parse_frontmatter(content) do
          %{"name" => name} = fm ->
            skill = %Skill{
              name: name,
              description: Map.get(fm, "description"),
              license: Map.get(fm, "license"),
              path: relative_to_repo(path)
            }

            {:ok, skill, fs}

          _ ->
            # Has SKILL.md but no `name:` — skip it. The smoke test catches
            # this case as a contract violation; here we just don't list.
            {:skip, fs}
        end

      {:error, _} ->
        {:skip, fs}
    end
  end

  # ── YAML front-matter parser (sized for the input we have) ─────────────
  #
  # SKILL.md files use a minimal YAML subset: top-level `key: value` pairs
  # between `---` delimiters, one per line, no nesting, no folded scalars.
  # No need to pull in a YAML library for this shape; the parser is 15
  # lines and handles the cases we actually see.

  defp parse_frontmatter(content) do
    case String.split(content, "\n") do
      ["---" | rest] ->
        {yaml_lines, _} = Enum.split_while(rest, &(&1 != "---"))

        yaml_lines
        |> Enum.flat_map(&parse_kv_line/1)
        |> Map.new()

      _ ->
        %{}
    end
  end

  defp parse_kv_line(line) do
    case Regex.run(~r/^([a-zA-Z_][\w-]*):\s+(.+)$/, line) do
      [_, key, value] -> [{key, String.trim(value)}]
      _ -> []
    end
  end

  # ── output ─────────────────────────────────────────────────────────────

  defp print(%Skill{} = s) do
    IO.puts("  #{s.name}")
    if s.description, do: IO.puts("    " <> truncate(s.description, 120))
    IO.puts("    " <> s.path)
    IO.puts("")
  end

  defp truncate(s, n) when byte_size(s) <= n, do: s
  defp truncate(s, n), do: String.slice(s, 0, n - 1) <> "…"

  defp relative_to_repo("/repo/" <> rest), do: rest
  defp relative_to_repo(p), do: p

  # ── helpers ────────────────────────────────────────────────────────────

  defp clone!(url) do
    case Exgit.clone(url, depth: 1) do
      {:ok, repo} ->
        repo

      {:error, reason} ->
        IO.puts(:stderr, "clone failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp time(fun) do
    start = System.monotonic_time(:microsecond)
    result = fun.()
    {System.monotonic_time(:microsecond) - start, result}
  end

  defp ms(us), do: "#{:erlang.float_to_binary(us / 1000, decimals: 0)}ms"
end

ListSkills.run()
