defmodule VFS.ConformanceCase do
  @moduledoc false
  # Shared `VFS.Mountable` conformance test set.
  #
  # Usage in a backend's test file:
  #
  #     defmodule VFS.MemoryTest do
  #       use VFS.ConformanceCase,
  #         backend: fn -> VFS.Memory.new() end,
  #         capabilities: [:read, :write, :chmod, :append]
  #     end
  #
  # The harness exercises every behavioral contract documented in
  # `VFS.Mountable`. Backends with reduced capabilities (e.g. read-only)
  # pass a different `:capabilities` list and the macro skips tests that
  # don't apply.

  defmacro __using__(opts) do
    factory = Keyword.fetch!(opts, :backend)
    capabilities = Keyword.get(opts, :capabilities, [:read, :write, :chmod, :append])

    quote location: :keep do
      use ExUnit.Case, async: true
      use ExUnitProperties

      @__backend_caps__ unquote(capabilities)

      defp fresh, do: unquote(factory).()

      defp writable?, do: :write in @__backend_caps__

      describe "stat/2" do
        test "regular file returns :regular type with correct size" do
          fs = fresh()

          if writable?() do
            {:ok, fs} = VFS.write_file(fs, "/a", "hello")
            {:ok, stat, _fs} = VFS.stat(fs, "/a")
            assert stat.type == :regular
            assert stat.size == 5
            assert match?(%DateTime{}, stat.mtime)
          end
        end

        test "non-existent path returns :enoent" do
          assert {:error, :enoent} = VFS.stat(fresh(), "/does/not/exist")
        end

        test "implicit directory returns :directory" do
          fs = fresh()

          if writable?() do
            {:ok, fs} = VFS.write_file(fs, "/a/b/c", "x")
            {:ok, stat, _fs} = VFS.stat(fs, "/a")
            assert stat.type == :directory
            {:ok, stat, _fs} = VFS.stat(fs, "/a/b")
            assert stat.type == :directory
          end
        end

        test "root is a directory" do
          {:ok, stat, _fs} = VFS.stat(fresh(), "/")
          assert stat.type == :directory
        end
      end

      describe "exists?/2" do
        test "true for an existing path, false otherwise" do
          fs = fresh()
          {false, _fs} = VFS.exists?(fs, "/x")

          if writable?() do
            {:ok, fs} = VFS.write_file(fs, "/x", "")
            {true, _fs} = VFS.exists?(fs, "/x")
            {false, _fs} = VFS.exists?(fs, "/y")
          end
        end
      end

      describe "readdir/2" do
        test "lists immediate children sorted" do
          fs = fresh()

          if writable?() do
            {:ok, fs} = VFS.write_file(fs, "/b", "1")
            {:ok, fs} = VFS.write_file(fs, "/a", "2")
            {:ok, fs} = VFS.write_file(fs, "/c", "3")
            {:ok, names, _fs} = VFS.readdir(fs, "/")
            assert names == ["a", "b", "c"]
          end
        end

        test "subdirectory listing only includes immediate children" do
          fs = fresh()

          if writable?() do
            {:ok, fs} = VFS.write_file(fs, "/dir/a", "1")
            {:ok, fs} = VFS.write_file(fs, "/dir/sub/b", "2")
            {:ok, names, _fs} = VFS.readdir(fs, "/dir")
            assert names == ["a", "sub"]
          end
        end

        test "non-existent dir returns :enoent" do
          assert {:error, :enoent} = VFS.readdir(fresh(), "/nope")
        end

        test "regular file returns :enotdir" do
          fs = fresh()

          if writable?() do
            {:ok, fs} = VFS.write_file(fs, "/file", "")
            assert {:error, :enotdir} = VFS.readdir(fs, "/file")
          end
        end
      end

      describe "read_file/2 + write_file/3" do
        test "round-trips arbitrary bytes" do
          if writable?() do
            fs = fresh()
            payload = :crypto.strong_rand_bytes(123)
            {:ok, fs} = VFS.write_file(fs, "/blob", payload)
            {:ok, ^payload, _fs} = VFS.read_file(fs, "/blob")
          end
        end

        test "overwrites existing content" do
          if writable?() do
            fs = fresh()
            {:ok, fs} = VFS.write_file(fs, "/a", "first")
            {:ok, fs} = VFS.write_file(fs, "/a", "second")
            {:ok, "second", _fs} = VFS.read_file(fs, "/a")
          end
        end

        test "non-existent path returns :enoent" do
          assert {:error, :enoent} = VFS.read_file(fresh(), "/missing")
        end

        test "directory returns :eisdir" do
          if writable?() do
            fs = fresh()
            {:ok, fs} = VFS.write_file(fs, "/d/x", "")
            assert {:error, :eisdir} = VFS.read_file(fs, "/d")
          end
        end
      end

      describe "stream_read/3" do
        test "chunks concatenate to the full content" do
          if writable?() do
            fs = fresh()
            payload = String.duplicate("abc", 1000)
            {:ok, fs} = VFS.write_file(fs, "/x", payload)
            {:ok, stream, _fs} = VFS.stream_read(fs, "/x")
            assert stream |> Enum.to_list() |> IO.iodata_to_binary() == payload
          end
        end

        test "respects :chunk_size" do
          if writable?() do
            fs = fresh()
            {:ok, fs} = VFS.write_file(fs, "/x", String.duplicate("a", 100))
            {:ok, stream, _fs} = VFS.stream_read(fs, "/x", chunk_size: 16)
            chunks = Enum.to_list(stream)
            assert Enum.all?(Enum.drop(chunks, -1), &(byte_size(&1) == 16))
            assert chunks |> IO.iodata_to_binary() |> byte_size() == 100
          end
        end

        test "non-existent returns :enoent" do
          assert {:error, :enoent} = VFS.stream_read(fresh(), "/missing")
        end
      end

      if :write in @__backend_caps__ do
        describe "write_file/3" do
          test "writes to nested existing dir" do
            fs = fresh()
            {:ok, fs} = VFS.mkdir(fs, "/dir", parents: true)
            {:ok, fs} = VFS.write_file(fs, "/dir/x", "ok")
            {:ok, "ok", _fs} = VFS.read_file(fs, "/dir/x")
          end

          test "writing onto a directory returns :eisdir" do
            fs = fresh()
            {:ok, fs} = VFS.write_file(fs, "/dir/x", "y")
            assert {:error, :eisdir} = VFS.write_file(fs, "/dir", "no")
          end
        end
      end

      if :append in @__backend_caps__ do
        describe "append_file/3" do
          test "appends to existing file" do
            fs = fresh()
            {:ok, fs} = VFS.write_file(fs, "/a", "hello")
            {:ok, fs} = VFS.append_file(fs, "/a", " world")
            {:ok, "hello world", _fs} = VFS.read_file(fs, "/a")
          end

          test "creates if missing" do
            fs = fresh()
            {:ok, fs} = VFS.append_file(fs, "/new", "first")
            {:ok, "first", _fs} = VFS.read_file(fs, "/new")
          end
        end
      end

      if :write in @__backend_caps__ do
        describe "mkdir/3" do
          test "creates an empty directory" do
            fs = fresh()
            {:ok, fs} = VFS.mkdir(fs, "/d")
            {:ok, stat, _fs} = VFS.stat(fs, "/d")
            assert stat.type == :directory
          end

          test "existing directory returns :eexist" do
            fs = fresh()
            {:ok, fs} = VFS.mkdir(fs, "/d")
            assert {:error, :eexist} = VFS.mkdir(fs, "/d")
          end

          test "missing parent without :parents returns :enoent" do
            fs = fresh()
            assert {:error, :enoent} = VFS.mkdir(fs, "/a/b")
          end

          test ":parents creates intermediates" do
            fs = fresh()
            {:ok, fs} = VFS.mkdir(fs, "/a/b/c", parents: true)
            {:ok, stat, _fs} = VFS.stat(fs, "/a/b")
            assert stat.type == :directory
          end
        end

        describe "rm/3" do
          test "removes a file" do
            fs = fresh()
            {:ok, fs} = VFS.write_file(fs, "/a", "")
            {:ok, fs} = VFS.rm(fs, "/a")
            assert {:error, :enoent} = VFS.read_file(fs, "/a")
          end

          test "non-existent returns :enoent" do
            assert {:error, :enoent} = VFS.rm(fresh(), "/no")
          end

          test "directory without :recursive returns :eisdir" do
            fs = fresh()
            {:ok, fs} = VFS.write_file(fs, "/d/x", "")
            assert {:error, :eisdir} = VFS.rm(fs, "/d")
          end

          test "directory with :recursive removes contents" do
            fs = fresh()
            {:ok, fs} = VFS.write_file(fs, "/d/x", "")
            {:ok, fs} = VFS.write_file(fs, "/d/sub/y", "")
            {:ok, fs} = VFS.rm(fs, "/d", recursive: true)
            assert {:error, :enoent} = VFS.read_file(fs, "/d/x")
            assert {:error, :enoent} = VFS.read_file(fs, "/d/sub/y")
          end
        end
      end

      if :chmod in @__backend_caps__ do
        describe "chmod/3" do
          test "sets mode bits on a file" do
            fs = fresh()
            {:ok, fs} = VFS.write_file(fs, "/a", "")
            {:ok, fs} = VFS.chmod(fs, "/a", 0o644)
            {:ok, stat, _fs} = VFS.stat(fs, "/a")
            assert stat.mode == 0o644
          end

          test "non-existent path returns :enoent" do
            assert {:error, :enoent} = VFS.chmod(fresh(), "/missing", 0o644)
          end
        end
      end

      describe "walk/3" do
        test "empty FS yields nothing" do
          assert fresh() |> VFS.walk("/") |> Enum.to_list() == []
        end

        test "yields all regular files (paths only)" do
          if writable?() do
            fs = fresh()
            {:ok, fs} = VFS.write_file(fs, "/a", "")
            {:ok, fs} = VFS.write_file(fs, "/b/c", "")
            {:ok, fs} = VFS.write_file(fs, "/b/sub/d", "")

            paths =
              fs
              |> VFS.walk("/")
              |> Enum.map(&elem(&1, 0))
              |> Enum.sort()

            assert paths == ["/a", "/b/c", "/b/sub/d"]
          end
        end

        test "include_dirs: true emits directory entries" do
          if writable?() do
            fs = fresh()
            {:ok, fs} = VFS.write_file(fs, "/d/x", "")

            paths =
              fs
              |> VFS.walk("/", include_dirs: true)
              |> Enum.map(&elem(&1, 0))
              |> Enum.sort()

            assert "/d" in paths or "/" in paths
          end
        end

        test "max_depth caps traversal" do
          if writable?() do
            fs = fresh()
            {:ok, fs} = VFS.write_file(fs, "/a", "")
            {:ok, fs} = VFS.write_file(fs, "/d/b", "")
            {:ok, fs} = VFS.write_file(fs, "/d/sub/c", "")

            paths =
              fs
              |> VFS.walk("/", max_depth: 1)
              |> Enum.map(&elem(&1, 0))
              |> Enum.sort()

            assert "/a" in paths
            refute "/d/sub/c" in paths
          end
        end
      end

      describe "state threading" do
        test "read returns an impl whose subsequent reads still succeed" do
          if writable?() do
            fs = fresh()
            {:ok, fs} = VFS.write_file(fs, "/a", "x")
            {:ok, _bin, fs2} = VFS.read_file(fs, "/a")
            {:ok, "x", _fs3} = VFS.read_file(fs2, "/a")
          end
        end

        test "write returns an impl that reflects the write" do
          if writable?() do
            fs = fresh()
            {:ok, fs2} = VFS.write_file(fs, "/a", "v")
            {:ok, "v", _fs3} = VFS.read_file(fs2, "/a")
          end
        end
      end

      describe "capabilities/1" do
        test "includes :read" do
          assert MapSet.member?(VFS.capabilities(fresh()), :read)
        end

        test "if :write is absent, mutations return :erofs or :enotsup" do
          fs = fresh()

          unless :write in @__backend_caps__ do
            for {result, _} <- [
                  {VFS.write_file(fs, "/x", ""), :write_file},
                  {VFS.mkdir(fs, "/d"), :mkdir},
                  {VFS.rm(fs, "/x"), :rm}
                ] do
              assert match?({:error, r} when r in [:erofs, :enotsup], result)
            end
          end
        end
      end

      describe "properties" do
        property "write/read round-trip preserves arbitrary bytes" do
          if writable?() do
            check all bytes <- binary(),
                      max_runs: 50 do
              fs = fresh()
              {:ok, fs} = VFS.write_file(fs, "/blob", bytes)
              {:ok, ^bytes, _fs} = VFS.read_file(fs, "/blob")
            end
          end
        end

        property "walk yields exactly the set of written file paths" do
          if writable?() do
            check all paths <- distinct_path_list(),
                      max_runs: 30 do
              fs =
                Enum.reduce(paths, fresh(), fn p, fs ->
                  {:ok, fs} = VFS.write_file(fs, p, "x")
                  fs
                end)

              walked = fs |> VFS.walk("/") |> Enum.map(&elem(&1, 0)) |> Enum.sort()
              assert walked == Enum.sort(paths)
            end
          end
        end

        property "path normalization is idempotent" do
          check all p <- absolute_path_string(), max_runs: 100 do
            once = VFS.Path.normalize(p)
            twice = VFS.Path.normalize(once)
            assert once == twice
          end
        end
      end

      defp distinct_path_list do
        StreamData.list_of(
          StreamData.member_of([
            "/a",
            "/b",
            "/c",
            "/d/x",
            "/d/y",
            "/d/sub/z",
            "/e/f/g",
            "/e/f/h"
          ]),
          min_length: 1,
          max_length: 6
        )
        |> StreamData.map(&Enum.uniq/1)
      end

      defp absolute_path_string do
        segs =
          StreamData.list_of(
            StreamData.member_of(["foo", "bar", "baz", ".", ".."]),
            min_length: 0,
            max_length: 5
          )

        StreamData.map(segs, fn parts -> "/" <> Enum.join(parts, "/") end)
      end
    end
  end
end
