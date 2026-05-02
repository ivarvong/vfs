defmodule VFS.Integration.CodesearchSmokeTest do
  @moduledoc """
  Real-network end-to-end smoke test against `https://github.com/anthropics/skills`.

  Exercises the full stack — `:exgit` HTTPS clone (depth=1), `%VFS{}`
  mount, `VFS.walk`, per-file `VFS.read_file`, regex grep — over a real
  public repository. Verifies the agent-loop scenario the design was
  built for actually works against a non-toy backend.

  Tagged `:integration_network` so default `mix test` skips it. Opt in
  with `mix test --include integration_network`. Has a generous
  per-test timeout because network latency is variable.

  ## Stability under repo growth

  Anthropic adds skills over time, so the test uses **lower-bound
  assertions** (`>= N`) rather than exact counts. The bounds are set
  generously below current numbers so normal repo growth doesn't break
  this test, but if a skill ever ships *without* the documented
  front-matter shape, the test still catches it.
  """
  use ExUnit.Case, async: false

  alias VFS.Test.ExgitMount

  @moduletag :integration_network
  @moduletag timeout: 60_000

  @repo_url "https://github.com/anthropics/skills.git"

  setup_all do
    case Exgit.clone(@repo_url, depth: 1) do
      {:ok, repo} ->
        fs = VFS.new() |> VFS.mount("/repo", ExgitMount.new(repo))
        {:ok, fs: fs}

      {:error, reason} ->
        flunk("""
        Failed to clone #{@repo_url}: #{inspect(reason)}

        This test requires network access. If you're running offline or
        the repo has moved, run with --exclude integration_network.
        """)
    end
  end

  test "walk yields a substantial file list", %{fs: fs} do
    paths = fs |> VFS.walk("/repo") |> Enum.map(&elem(&1, 0))

    # Repo grows over time; bounds are generously below current numbers
    # (~390 files) so adding skills doesn't break this test.
    assert length(paths) > 100,
           "expected >100 files in anthropics/skills, got #{length(paths)}"

    # All emitted paths share the mount prefix.
    assert Enum.all?(paths, &String.starts_with?(&1, "/repo/"))
  end

  test "every SKILL.md has well-formed YAML front-matter", %{fs: fs} do
    skills =
      fs
      |> VFS.walk("/repo")
      |> Enum.map(&elem(&1, 0))
      |> Enum.filter(&String.ends_with?(&1, "/SKILL.md"))

    assert length(skills) >= 10,
           "expected >=10 SKILL.md files, got #{length(skills)}"

    {missing_name, missing_desc, missing_delim, _fs} =
      Enum.reduce(skills, {[], [], [], fs}, fn path, {mn, md, mdel, fs} ->
        {:ok, content, fs} = VFS.read_file(fs, path)

        mn = if has_field?(content, "name"), do: mn, else: [path | mn]
        md = if has_field?(content, "description"), do: md, else: [path | md]
        mdel = if has_yaml_delimiters?(content), do: mdel, else: [path | mdel]

        {mn, md, mdel, fs}
      end)

    assert missing_name == [], "SKILL.md missing `name:` field: #{inspect(missing_name)}"
    assert missing_desc == [], "SKILL.md missing `description:` field: #{inspect(missing_desc)}"

    assert missing_delim == [],
           "SKILL.md missing `---` YAML delimiters: #{inspect(missing_delim)}"
  end

  test "grep across the whole repo for `^# ` returns expected magnitudes", %{fs: fs} do
    paths = fs |> VFS.walk("/repo") |> Enum.map(&elem(&1, 0))

    {fs, total_matches, files_with_matches} =
      Enum.reduce(paths, {fs, 0, 0}, fn path, {fs, total, files} ->
        case VFS.read_file(fs, path) do
          {:ok, content, fs} ->
            n =
              content
              |> String.split("\n")
              |> Enum.count(&Regex.match?(~r/^# /, &1))

            {fs, total + n, if(n > 0, do: files + 1, else: files)}

          {:error, _} ->
            {fs, total, files}
        end
      end)

    _ = fs

    # Lower bounds based on observed numbers (371 / 87) at the time of
    # writing. Sized to absorb growth without false negatives.
    assert total_matches >= 100,
           "expected >=100 markdown headers across the repo, got #{total_matches}"

    assert files_with_matches >= 30,
           "expected >=30 files with markdown headers, got #{files_with_matches}"
  end

  # ── helpers ──────────────────────────────────────────────────────────

  # `~r/^name:\s+\S/m` — `name:` followed by whitespace and at least one
  # non-whitespace char. Multiline anchor lets `^` match line starts.
  defp has_field?(content, field) do
    Regex.match?(~r/^#{field}:\s+\S/m, content)
  end

  # YAML front-matter is delimited by `---` lines. Most SKILL.md files
  # open with `---\n...\n---` at the top.
  defp has_yaml_delimiters?(content) do
    case String.split(content, "\n", parts: 3) do
      ["---" | _] -> true
      _ -> false
    end
  end
end
