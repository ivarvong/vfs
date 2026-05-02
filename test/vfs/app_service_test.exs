defmodule VFS.AppServiceTest do
  @moduledoc """
  Tests for `VFS.Test.AppService` — the postgres-shaped backend.
  Plus the full read/write conformance suite via `VFS.ConformanceCase`,
  which proves the protocol contract holds against this backend's
  flat-keyed write-through-cache shape.
  """
  use VFS.ConformanceCase,
    backend: fn -> VFS.Test.AppService.new() end,
    capabilities: [:read, :write]

  alias VFS.Test.AppService

  describe "AppService — postgres-shaped specifics" do
    test "write-through cache: read after write hits cache, no miss" do
      svc = AppService.new()
      {:ok, svc} = VFS.Mountable.write_file(svc, "/a", "x", [])

      # write_file populates the cache directly (write-through), so the
      # first read after a write is already a cache hit. This matters
      # for LLM tool flows where write→read is a common pattern.
      {:ok, _, svc} = VFS.Mountable.stream_read(svc, "/a", [])
      assert svc.misses == 0
      assert svc.hits == 1
    end

    test "materialize with prefix: only the working set is loaded" do
      seed = for i <- 1..100, into: %{}, do: {"/users/U#{i}/name", "user #{i}"}
      seed = Map.merge(seed, %{"/admin/secret" => "..."})
      svc = AppService.new(seed)

      {:ok, primed} = VFS.Mountable.materialize(svc, prefix: "/users")

      # /users/* in cache; /admin/* not
      assert map_size(primed.cache) == 100
      refute Map.has_key?(primed.cache, "/admin/secret")
    end

    test "rm of a key with cached entry purges the cache too" do
      svc = AppService.new(%{"/x" => "data"})
      {:ok, _content, svc} = VFS.Mountable.stream_read(svc, "/x", [])
      assert Map.has_key?(svc.cache, "/x")

      {:ok, svc} = VFS.Mountable.rm(svc, "/x", [])
      refute Map.has_key?(svc.cache, "/x")
    end

    test "mkdir is :enotsup — postgres-shaped stores have no empty dirs" do
      assert {:error, %VFS.Error{kind: :enotsup}} =
               VFS.Mountable.mkdir(AppService.new(), "/empty_dir", [])
    end
  end
end
