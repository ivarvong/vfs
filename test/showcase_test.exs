defmodule VFS.ShowcaseTest do
  @moduledoc """
  How to use `:vfs` in agent loops. Three backends, three workflows,
  one threaded `%VFS{}` value.

  Audience: a CTO building agent loops who needs to see, in one file,
  what consuming this library actually looks like under load.

  Run as a tour:

      mix test test/showcase_test.exs --trace                              # local sections only
      mix test test/showcase_test.exs --trace --include integration_network  # + real GitHub clone

  ## The shape

  An agent loop's filesystem is rarely just one backend. A real
  application typically composes:

    1. **Read-only codebase** — git, mounted at `/repo`. The agent
       reads code/docs as input. Read latency matters; cache hits
       across read sequences are essential.
    2. **Read-write scratch** — in-memory, mounted at `/scratch`.
       Intermediate state during one agent invocation: derived
       artifacts, working files, prompt fragments. Discarded between
       invocations.
    3. **Read-write application service** — postgres, mounted at
       `/app`. Durable per-tenant state: user profiles, conversation
       history, session memory, evaluation results. Survives across
       invocations and across processes.

  All three sit behind one `%VFS{}` value. The agent threads that
  value through every step of the loop. Reads return updated values
  whose caches are warm; writes return updated values whose state
  reflects the change. There's no shared mutable state, no process
  registry, no global cache — just a value flowing through pipe-style
  operations, the way `Plug.Conn` flows through a request pipeline.

  ## What this file covers

    1. Solo: in-memory scratch only (the simplest agent invocation)
    2. Read-only codebase via git (real network, opt-in)
    3. App service backend (fake postgres for demo; same protocol shape)
    4. The full loop: codebase + scratch + app service threaded together

  Each section is self-contained and runnable. Skip what doesn't apply.
  """
  use ExUnit.Case, async: true

  alias VFS.Test.{AppService, ExgitMount}

  # ─────────────────────────────────────────────────────────────────────
  # 1. SOLO AGENT — in-memory scratch only
  # ─────────────────────────────────────────────────────────────────────
  #
  # A one-shot agent that writes intermediate state, reads it back,
  # produces output. No external storage. The whole FS is ephemeral
  # to this one invocation.
  #
  # When this is the right shape:
  #   - Stateless agent steps that need a place to compose intermediate
  #     artifacts (a python script writes a CSV, a follow-up step reads it)
  #   - Sandboxing tool calls that shouldn't see the host filesystem
  #   - Per-request scratch isolated from sibling agent invocations
  describe "1. solo agent: in-memory scratch only" do
    test "intermediate state written by step 1 is read by step 2" do
      fs = VFS.new() |> VFS.mount("/", VFS.Memory.new(%{}))

      # Step 1: agent runs a "tool" that produces a CSV.
      csv = "id,score\n1,0.91\n2,0.87\n3,0.42\n"
      {:ok, fs} = VFS.write_file(fs, "/results.csv", csv)

      # Step 2: agent runs a follow-up that consumes the CSV.
      {:ok, content, fs} = VFS.read_file(fs, "/results.csv")

      top_score =
        content
        |> String.split("\n", trim: true)
        |> Enum.drop(1)
        |> Enum.map(fn row -> row |> String.split(",") |> List.last() |> String.to_float() end)
        |> Enum.max()

      assert top_score == 0.91

      # Step 3: agent writes its conclusion. The threaded `fs` carries
      # /results.csv and /summary.txt.
      {:ok, fs} = VFS.write_file(fs, "/summary.txt", "winner: 1 (#{top_score})")

      paths = fs |> VFS.walk("/") |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      assert paths == ["/results.csv", "/summary.txt"]
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # 2. READ-ONLY CODEBASE — git-backed, real network
  # ─────────────────────────────────────────────────────────────────────
  #
  # The agent's input: a git repository it reads from. Cloned shallow
  # (depth=1) so we only fetch HEAD's tree+blobs, not history.
  # `:exgit` is a pure-Elixir git client, so this works in releases,
  # Lambda, Nerves — anywhere with HTTPS, no `git` binary needed.
  #
  # The pattern an agent uses:
  #   1. Clone (or open an existing local repo).
  #   2. Mount through VFS.
  #   3. Read files. Each read populates the lazy backend's cache.
  #   4. (Optional) `VFS.materialize` ahead of bulk reads for one
  #      batch fetch instead of N round-trips.
  describe "2. read-only codebase via real git clone" do
    @describetag :integration_network
    @describetag timeout: 60_000

    test "clone, mount, answer a structured query" do
      # Clone shallow; mount; query.
      {:ok, repo} = Exgit.clone("https://github.com/anthropics/skills.git", depth: 1)
      fs = VFS.new() |> VFS.mount("/repo", ExgitMount.new(repo))

      # The query: "what skills exist in this repo?" — structured,
      # not regex grep. We walk → filter to SKILL.md → parse YAML
      # front-matter → return records.
      skills =
        fs
        |> VFS.walk("/repo")
        |> Stream.map(&elem(&1, 0))
        |> Stream.filter(&String.ends_with?(&1, "/SKILL.md"))
        |> Enum.flat_map(&parse_skill(fs, &1))

      assert length(skills) >= 10

      # Specific skills we expect to exist as long as the repo's
      # contents are what they say.
      names = Enum.map(skills, & &1.name) |> MapSet.new()
      assert "pdf" in names
      assert "skill-creator" in names

      # See `examples/list_skills.exs` for the fully-formatted variant.
    end

    test "materialize prewarms the cache before bulk reads" do
      {:ok, repo} = Exgit.clone("https://github.com/anthropics/skills.git", depth: 1)
      mount = ExgitMount.new(repo)

      # Without prewarm: every read could trigger a fetch in a real
      # partial-clone repo. (Shallow clone is already eager so this
      # is mostly demonstrative — a `lazy: true, filter: {:blob, :none}`
      # clone is where the lever earns its cost.)
      {:ok, primed} = VFS.Mountable.materialize(mount, [])
      assert match?(%ExgitMount{}, primed)
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # 3. APP SERVICE BACKEND — postgres-shaped, durable per-tenant state
  # ─────────────────────────────────────────────────────────────────────
  #
  # Every agent loop that touches users, conversations, or sessions
  # needs durable state somewhere. The standard answer is postgres.
  # Exposing it via `VFS.Mountable` means the same primitives that
  # read/walk/grep code also read/walk/grep application data.
  #
  # `VFS.Test.AppService` is a fake — same protocol surface as a real
  # postgres-backed `VFS.AppService` would have, but the storage is a
  # `Map` instead of a connection pool. Productionizing means swapping
  # the read/write internals; the protocol contract is identical.
  describe "3. app service backend (postgres-shaped)" do
    test "user/conversation/session paths — like an actual app's data model" do
      svc =
        AppService.new(%{
          "/users/U123/profile.json" => ~s({"name":"Ivar","tier":"pro"}),
          "/conversations/C42/messages.jsonl" =>
            ~s({"role":"user","content":"hi"}\n{"role":"assistant","content":"hello"}),
          "/sessions/S99/state.json" => ~s({"step":3})
        })

      fs = VFS.new() |> VFS.mount("/app", svc)

      # Read the user's profile.
      {:ok, profile, fs} = VFS.read_file(fs, "/app/users/U123/profile.json")
      assert String.contains?(profile, "Ivar")

      # Append a turn to the conversation. write_file is upsert; the
      # cache for this path is updated in place.
      old =
        case VFS.read_file(fs, "/app/conversations/C42/messages.jsonl") do
          {:ok, c, _} -> c
          _ -> ""
        end

      new_log = old <> ~s(\n{"role":"user","content":"another"})
      {:ok, fs} = VFS.write_file(fs, "/app/conversations/C42/messages.jsonl", new_log)

      # Re-read: returns the new content (write-through cache).
      {:ok, current, _fs} = VFS.read_file(fs, "/app/conversations/C42/messages.jsonl")
      assert String.contains?(current, "another")
    end

    test "materialize prefetches a working set in one batch" do
      svc =
        AppService.new(for i <- 1..50, into: %{}, do: {"/users/U#{i}/profile.json", "user #{i}"})

      # Real postgres impl: SELECT path, content FROM paths
      # WHERE path LIKE '/users/%'  — one round trip for 50 rows.
      {:ok, primed} = VFS.Mountable.materialize(svc, prefix: "/users")

      # 50 reads now, 0 misses — the working set is loaded.
      {svc, misses_before} = {primed, primed.misses}

      svc =
        Enum.reduce(1..50, svc, fn i, acc ->
          {:ok, _, acc} = VFS.Mountable.stream_read(acc, "/users/U#{i}/profile.json", [])
          acc
        end)

      assert svc.hits == 50
      assert svc.misses == misses_before
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # 4. THE FULL LOOP — codebase + scratch + app service together
  # ─────────────────────────────────────────────────────────────────────
  #
  # The shape an actual agent application has:
  #   /repo     → read-only codebase
  #   /scratch  → ephemeral working files for this invocation
  #   /app      → durable per-tenant state
  #
  # The agent threads ONE `%VFS{}` through every step. Each step gets
  # the FS, does a read or write, returns the updated FS. The next step
  # sees every cache populated by the previous step's reads.
  describe "4. full loop: codebase + scratch + app service" do
    test "agent reads code from /repo, computes, writes to /scratch and /app" do
      # Set up the three mounts. In production: exgit clone, app's
      # postgres pool. Here we use seeded fakes so the test runs
      # offline.
      codebase =
        VFS.Test.GitFake.commit(%{
          "/lib/important.ex" => "defmodule Important do\n  def go, do: :ok\nend",
          "/lib/other.ex" => "defmodule Other do end",
          "/test/important_test.exs" => "defmodule ImportantTest do end"
        })

      app =
        AppService.new(%{
          "/users/U123/profile.json" => ~s({"name":"Ivar","tier":"pro"})
        })

      fs =
        VFS.new()
        |> VFS.mount("/repo", codebase)
        |> VFS.mount("/scratch", VFS.Memory.new())
        |> VFS.mount("/app", app)

      # Step 1: read the user's profile from app state.
      {:ok, profile, fs} = VFS.read_file(fs, "/app/users/U123/profile.json")
      assert String.contains?(profile, "Ivar")

      # Step 2: walk the codebase, find the lib/ files.
      lib_files =
        fs
        |> VFS.walk("/repo/lib")
        |> Stream.map(&elem(&1, 0))
        |> Enum.sort()

      assert lib_files == ["/repo/lib/important.ex", "/repo/lib/other.ex"]

      # Step 3: read one of them, compute a derived artifact.
      {:ok, code, fs} = VFS.read_file(fs, "/repo/lib/important.ex")
      module_name = ~r/defmodule\s+(\S+)\s/ |> Regex.run(code) |> Enum.at(1)
      assert module_name == "Important"

      # Step 4: write the derived artifact to scratch (ephemeral).
      summary = "module: #{module_name}\nbytes: #{byte_size(code)}\n"
      {:ok, fs} = VFS.write_file(fs, "/scratch/summary.txt", summary)

      # Step 5: persist a finding to app state (durable).
      finding = ~s({"user":"U123","module":"#{module_name}","ts":"2026-01-01"})
      {:ok, fs} = VFS.write_file(fs, "/app/users/U123/findings/F1.json", finding)

      # Verify all three mounts have what we expect.
      {:ok, ^summary, fs} = VFS.read_file(fs, "/scratch/summary.txt")
      {:ok, persisted, fs} = VFS.read_file(fs, "/app/users/U123/findings/F1.json")
      assert String.contains?(persisted, "Important")

      # readdir traverses the synthesized top-level: the three mounts
      # appear as virtual directories at /.
      {:ok, names, _fs} = VFS.readdir(fs, "/")
      assert Enum.sort(Enum.to_list(names)) == ["app", "repo", "scratch"]
    end

    test "errors are structured — pattern-match on :kind, log :path and :mount" do
      fs =
        VFS.new()
        |> VFS.mount("/repo", VFS.Test.GitFake.commit(%{"/a.ex" => "x"}))
        |> VFS.mount("/scratch", VFS.Memory.new())

      # Read of a non-existent path returns a struct, not just an atom.
      {:error, err} = VFS.read_file(fs, "/repo/nope.ex")
      assert err.kind == :enoent
      assert err.path == "/repo/nope.ex"
      assert err.mount == "/repo"

      # Writes to the read-only codebase are refused with :erofs —
      # the agent code can branch on this without trying to inspect
      # error message strings.
      {:error, err} = VFS.write_file(fs, "/repo/anything.ex", "...")
      assert err.kind == :erofs
    end

    test "telemetry — every public op emits start/stop" do
      # The library has no opinion about logging, OTel, or metrics —
      # it just emits :telemetry events. Consumers route them.
      #
      # Module-qualified capture (`&__MODULE__.handle_telemetry/4`)
      # avoids telemetry's local-function performance warning.
      pid = self()

      :ok =
        :telemetry.attach(
          "showcase",
          [:vfs, :read_file, :stop],
          &__MODULE__.handle_telemetry/4,
          pid
        )

      fs =
        VFS.new() |> VFS.mount("/scratch", VFS.Memory.new())

      {:ok, fs} = VFS.write_file(fs, "/scratch/x", "hi")
      {:ok, "hi", _} = VFS.read_file(fs, "/scratch/x")

      assert_receive {:read_done, %{duration: d, bytes: 2}, %{path: "/scratch/x", impl: VFS}}
                     when d > 0

      :telemetry.detach("showcase")
    end
  end

  # ── telemetry handler (must be a module-qualified function, not a closure) ──

  @doc false
  def handle_telemetry(_event, measurements, metadata, pid) do
    send(pid, {:read_done, measurements, metadata})
  end

  # ── helpers used in section 2 ──────────────────────────────────────────

  defp parse_skill(fs, path) do
    {:ok, content, _fs} = VFS.read_file(fs, path)

    case parse_frontmatter(content) do
      %{"name" => name, "description" => description} ->
        [%{name: name, description: description, path: path}]

      _ ->
        []
    end
  end

  defp parse_frontmatter(content) do
    case String.split(content, "\n") do
      ["---" | rest] ->
        {yaml, _} = Enum.split_while(rest, &(&1 != "---"))

        yaml
        |> Enum.flat_map(fn line ->
          case Regex.run(~r/^([a-zA-Z_][\w-]*):\s+(.+)$/, line) do
            [_, k, v] -> [{k, String.trim(v)}]
            _ -> []
          end
        end)
        |> Map.new()

      _ ->
        %{}
    end
  end
end
