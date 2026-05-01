defmodule VFS.TelemetryTest do
  @moduledoc """
  Asserts the documented telemetry event taxonomy. Each public op in `VFS`
  emits a `[:vfs, op, :start]` and `[:vfs, op, :stop]` pair with the
  expected metadata and measurement keys. `[:vfs, :cache, :hit | :miss]`
  events are emitted by lazy backends themselves.
  """
  use ExUnit.Case, async: false

  alias VFS.Test.{LazyFake, TelemetryHelper}

  setup do
    {:ok,
     handler:
       TelemetryHelper.attach!([
         [:vfs, :read_file],
         [:vfs, :write_file],
         [:vfs, :stream_read],
         [:vfs, :walk],
         [:vfs, :grep],
         [:vfs, :glob],
         [:vfs, :materialize],
         [:vfs, :mkdir],
         [:vfs, :rm],
         [:vfs, :append_file],
         [:vfs, :chmod]
       ])}
  end

  test "read_file emits :start then :stop with bytes" do
    fs = VFS.new(%{"/a" => "hello"})
    {:ok, "hello", _} = VFS.read_file(fs, "/a")

    assert_received {:telemetry, [:vfs, :read_file, :start], %{system_time: _},
                     %{path: "/a", impl: VFS}}

    assert_received {:telemetry, [:vfs, :read_file, :stop], %{duration: _, bytes: 5},
                     %{path: "/a", impl: VFS}}
  end

  test "read_file emits :stop with bytes: 0 and :error on failure" do
    fs = VFS.new()
    {:error, :enoent} = VFS.read_file(fs, "/missing")

    assert_received {:telemetry, [:vfs, :read_file, :start], _, _}

    assert_received {:telemetry, [:vfs, :read_file, :stop], %{bytes: 0}, %{error: :enoent}}
  end

  test "write_file emits :start with bytes, :stop with duration" do
    fs = VFS.new(%{})
    {:ok, _} = VFS.write_file(fs, "/a", "abc")

    assert_received {:telemetry, [:vfs, :write_file, :start], _, %{path: "/a", bytes: 3}}

    assert_received {:telemetry, [:vfs, :write_file, :stop], %{duration: _}, _}
  end

  test "walk emits terminal :start/:stop with entries count" do
    fs = VFS.new(%{"/a" => "1", "/b/c" => "2"})

    fs |> VFS.walk("/") |> Enum.to_list()

    assert_received {:telemetry, [:vfs, :walk, :start], %{system_time: _}, %{root: "/", impl: VFS}}

    assert_received {:telemetry, [:vfs, :walk, :stop], %{duration: _, entries: 2}, _}
  end

  test "grep emits terminal :stop with matches count" do
    fs = VFS.new(%{"/a" => "todo: x\nokay\nTODO again\n"})

    fs |> VFS.grep("/", ~r/TODO/i) |> Enum.to_list()

    assert_received {:telemetry, [:vfs, :grep, :start], _, _}
    assert_received {:telemetry, [:vfs, :grep, :stop], %{matches: 2}, _}
  end

  test "glob emits terminal :stop with matches count" do
    fs = VFS.new(%{"/a.ex" => "", "/b.exs" => "", "/c.ex" => ""})

    fs |> VFS.glob("/", "*.ex") |> Enum.to_list()

    assert_received {:telemetry, [:vfs, :glob, :start], _, _}
    assert_received {:telemetry, [:vfs, :glob, :stop], %{matches: 2}, _}
  end

  test "materialize emits :start/:stop" do
    fs = VFS.new()
    {:ok, _} = VFS.materialize(fs)

    assert_received {:telemetry, [:vfs, :materialize, :start], _, _}
    assert_received {:telemetry, [:vfs, :materialize, :stop], %{duration: _}, _}
  end

  test "mkdir emits :start/:stop" do
    fs = VFS.new(%{})
    {:ok, _} = VFS.mkdir(fs, "/d")

    assert_received {:telemetry, [:vfs, :mkdir, :start], _, _}
    assert_received {:telemetry, [:vfs, :mkdir, :stop], _, _}
  end

  test "rm emits :start/:stop" do
    fs = VFS.new(%{"/a" => ""})
    {:ok, _} = VFS.rm(fs, "/a")

    assert_received {:telemetry, [:vfs, :rm, :start], _, _}
    assert_received {:telemetry, [:vfs, :rm, :stop], _, _}
  end

  test "lazy backend emits :cache, :miss on first read and :cache, :hit on second" do
    TelemetryHelper.attach!([[:vfs, :cache, :hit], [:vfs, :cache, :miss]])

    lf = LazyFake.new(%{"/a" => "x"})

    {:ok, _, lf} = VFS.Mountable.read_file(lf, "/a")
    assert_received {:telemetry, [:vfs, :cache, :miss], %{}, %{path: "/a"}}

    {:ok, _, _} = VFS.Mountable.read_file(lf, "/a")
    assert_received {:telemetry, [:vfs, :cache, :hit], %{}, %{path: "/a"}}
  end
end
