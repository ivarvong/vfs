defmodule VFS.GitFakeTest do
  @moduledoc """
  Tests for `VFS.Test.GitFake` — the content-addressed lazy backend.
  Exercises the protocol features that distinguish a real-world lazy
  backend (cache, materialize, cache telemetry, read-only enforcement,
  content-addressed deduplication) beyond what the conformance suite
  alone proves.
  """
  use ExUnit.Case, async: true

  alias VFS.Test.{GitFake, TelemetryHelper}

  describe "construction and content-addressing" do
    test "commit/1 builds a tree of {sha, size} entries" do
      repo = GitFake.commit(%{"/a" => "hello"})
      {sha, size} = Map.fetch!(repo.tree, "/a")

      assert size == 5
      assert sha == GitFake.sha_of("hello")
    end

    test "identical content at different paths shares one object" do
      repo = GitFake.commit(%{"/a" => "x", "/b" => "x", "/c" => "x"})
      assert map_size(repo.tree) == 3
      assert map_size(repo.objects) == 1
    end

    test "different content produces different SHAs" do
      repo = GitFake.commit(%{"/a" => "one", "/b" => "two"})
      assert map_size(repo.objects) == 2
    end
  end

  describe "lazy fetch + cache via state threading" do
    setup do
      {:ok, repo: GitFake.commit(%{"/a" => "hello", "/b" => "world", "/dir/c" => "nested"})}
    end

    test "first read of a path is a miss, second (with state threaded) is a hit", %{repo: repo} do
      assert {repo.hits, repo.misses} == {0, 0}

      {:ok, "hello", repo} = VFS.Mountable.stream_read(repo, "/a", []) |> collapse()
      assert {repo.hits, repo.misses} == {0, 1}

      {:ok, "hello", repo} = VFS.Mountable.stream_read(repo, "/a", []) |> collapse()
      assert {repo.hits, repo.misses} == {1, 1}
    end

    test "throwing returned state away forces every read to re-fetch", %{repo: repo} do
      {:ok, "hello", _} = VFS.Mountable.stream_read(repo, "/a", []) |> collapse()
      {:ok, "hello", repo2} = VFS.Mountable.stream_read(repo, "/a", []) |> collapse()

      # Both reads started from the original repo; neither saw the cache update
      # from the other. Two misses.
      assert repo2.misses == 1
      assert repo2.hits == 0
    end

    test "different paths sharing the same SHA share a cache slot", %{} do
      repo = GitFake.commit(%{"/a" => "shared", "/b" => "shared"})

      {:ok, "shared", repo} = VFS.Mountable.stream_read(repo, "/a", []) |> collapse()
      assert {repo.hits, repo.misses} == {0, 1}

      # Reading /b finds the same SHA already cached — the content-addressed
      # cache hits *across* paths. This is a real win over by-path caching.
      {:ok, "shared", repo} = VFS.Mountable.stream_read(repo, "/b", []) |> collapse()
      assert {repo.hits, repo.misses} == {1, 1}
    end
  end

  describe "materialize/2 pre-warms the cache" do
    test "after materialize, every read is a hit and N reads → 0 misses" do
      repo = GitFake.commit(%{"/a" => "1", "/b" => "2", "/dir/c" => "3"})

      {:ok, repo} = VFS.Mountable.materialize(repo, [])

      {:ok, "1", repo} = VFS.Mountable.stream_read(repo, "/a", []) |> collapse()
      {:ok, "2", repo} = VFS.Mountable.stream_read(repo, "/b", []) |> collapse()
      {:ok, "3", repo} = VFS.Mountable.stream_read(repo, "/dir/c", []) |> collapse()

      assert {repo.hits, repo.misses} == {3, 0}
    end

    test "materialize only fetches blobs referenced by the tree" do
      # Construct a repo where the objects store has *more* than the tree
      # references — like a real partial-clone repo.
      repo = %GitFake{
        tree: %{"/a" => {"sha-a", 1}},
        objects: %{
          "sha-a" => "x",
          "sha-orphan-1" => "leftover",
          "sha-orphan-2" => "another leftover"
        }
      }

      {:ok, repo} = VFS.Mountable.materialize(repo, [])
      assert map_size(repo.cache) == 1
      assert Map.has_key?(repo.cache, "sha-a")
    end
  end

  describe "telemetry: cache events" do
    test "[:vfs, :cache, :hit] and [:vfs, :cache, :miss] emit with path metadata" do
      TelemetryHelper.attach!([[:vfs, :cache, :hit], [:vfs, :cache, :miss]])

      repo = GitFake.commit(%{"/x" => "data"})

      {:ok, _, repo} = VFS.Mountable.stream_read(repo, "/x", []) |> collapse()

      assert_received {:telemetry, [:vfs, :cache, :miss], %{},
                       %{path: "/x", impl: VFS.Test.GitFake}}

      {:ok, _, _} = VFS.Mountable.stream_read(repo, "/x", []) |> collapse()
      assert_received {:telemetry, [:vfs, :cache, :hit], %{}, %{path: "/x", impl: VFS.Test.GitFake}}
    end
  end

  describe "read-only enforcement" do
    test "all mutations return :erofs" do
      repo = GitFake.commit(%{"/a" => "x"})

      assert {:error, %VFS.Error{kind: :erofs}} = VFS.Mountable.write_file(repo, "/a", "y", [])
      assert {:error, %VFS.Error{kind: :erofs}} = VFS.Mountable.mkdir(repo, "/d", [])
      assert {:error, %VFS.Error{kind: :erofs}} = VFS.Mountable.rm(repo, "/a", [])
    end

    test "capabilities reports :read and :lazy, not :write" do
      caps = VFS.Mountable.capabilities(GitFake.commit(%{}))
      assert MapSet.member?(caps, :read)
      assert MapSet.member?(caps, :lazy)
      refute MapSet.member?(caps, :write)
    end
  end

  describe "tree navigation" do
    setup do
      {:ok,
       repo:
         GitFake.commit(%{
           "/README.md" => "# Project",
           "/src/lib.ex" => "defmodule Lib do end",
           "/src/main.ex" => "defmodule Main do end",
           "/test/lib_test.exs" => "defmodule LibTest do end"
         })}
    end

    test "readdir at root lists top-level entries", %{repo: repo} do
      {:ok, names, _} = VFS.Mountable.readdir(repo, "/")
      assert Enum.to_list(names) == ["README.md", "src", "test"]
    end

    test "readdir at a subdirectory lists immediate children only", %{repo: repo} do
      {:ok, names, _} = VFS.Mountable.readdir(repo, "/src")
      assert Enum.to_list(names) == ["lib.ex", "main.ex"]
    end

    test "walk yields every file path under the tree", %{repo: repo} do
      paths =
        repo
        |> VFS.Mountable.walk("/", [])
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      assert paths == [
               "/README.md",
               "/src/lib.ex",
               "/src/main.ex",
               "/test/lib_test.exs"
             ]
    end
  end

  describe "use through the mount table" do
    test "mounting GitFake at /repo works end-to-end" do
      repo = GitFake.commit(%{"/README.md" => "hello"})
      fs = VFS.new() |> VFS.mount("/repo", repo)

      {:ok, "hello", fs} = VFS.read_file(fs, "/repo/README.md")
      {:ok, names, _} = VFS.readdir(fs, "/repo")
      assert Enum.to_list(names) == ["README.md"]

      # Cache state is threaded back into the mount table — re-reading
      # the same path is a hit on the inner GitFake.
      {:ok, "hello", _fs} = VFS.read_file(fs, "/repo/README.md")
      [{"/repo", inner}] = fs.mounts
      assert inner.hits + inner.misses >= 1
    end

    test "VFS.materialize through the mount table prewarms the GitFake cache" do
      repo = GitFake.commit(%{"/a" => "1", "/b" => "2"})
      fs = VFS.new() |> VFS.mount("/repo", repo)

      {:ok, fs} = VFS.materialize(fs)

      {:ok, _, fs} = VFS.read_file(fs, "/repo/a")
      {:ok, _, fs} = VFS.read_file(fs, "/repo/b")

      [{"/repo", inner}] = fs.mounts
      assert inner.hits == 2
      assert inner.misses == 0
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp collapse({:ok, [content], impl}), do: {:ok, content, impl}

  defp collapse({:ok, stream, impl}),
    do: {:ok, stream |> Enum.to_list() |> IO.iodata_to_binary(), impl}

  defp collapse(err), do: err
end

defmodule VFS.GitFakeConformanceTest do
  @moduledoc """
  Run the conformance suite against `VFS.Test.GitFake` (read-only).
  This proves the read-side of the protocol is generic — the same test
  set that runs against `VFS.Memory` (a fully-mutable in-memory backend)
  also runs cleanly against a content-addressed lazy read-only backend.
  """
  use VFS.ConformanceCase,
    backend: fn -> VFS.Test.GitFake.commit(%{}) end,
    capabilities: [:read, :lazy]
end
