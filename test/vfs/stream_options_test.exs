defmodule VFS.StreamOptionsTest do
  @moduledoc """
  Direct tests for `VFS.StreamOptions.apply/2`. The helper is shared
  across every backend whose `stream_read/3` returns bytes — Memory,
  AppService, future Postgrex/S3 backends. Every behavior here must
  hold or it's a contract violation across multiple backends.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias VFS.StreamOptions

  describe "apply/2 guard rejects malformed inputs" do
    # `apply/3` is used to defeat compiler type narrowing — these
    # tests verify the runtime guard, not the static contract.
    test "non-binary content raises FunctionClauseError" do
      assert_raise FunctionClauseError, fn ->
        apply(StreamOptions, :apply, [:not_a_binary, []])
      end

      assert_raise FunctionClauseError, fn ->
        apply(StreamOptions, :apply, [123, []])
      end
    end

    test "non-list opts raises FunctionClauseError" do
      assert_raise FunctionClauseError, fn ->
        apply(StreamOptions, :apply, ["content", %{chunk_size: 64}])
      end
    end
  end

  describe "apply/2 happy path" do
    test "no opts: returns the whole content as one chunk" do
      {:ok, stream} = StreamOptions.apply("hello", [])
      assert stream |> Enum.to_list() |> IO.iodata_to_binary() == "hello"
    end

    test "empty content yields an empty stream regardless of opts" do
      {:ok, stream} = StreamOptions.apply("", [])
      assert Enum.to_list(stream) == []

      {:ok, stream} = StreamOptions.apply("", chunk_size: 10)
      assert Enum.to_list(stream) == []
    end

    test "chunk_size: 1 produces one byte per chunk" do
      {:ok, stream} = StreamOptions.apply("abc", chunk_size: 1)
      assert Enum.to_list(stream) == ["a", "b", "c"]
    end
  end

  describe "apply/2 invalid opts → :einval" do
    test "non-integer chunk_size" do
      assert {:error, :einval} = StreamOptions.apply("x", chunk_size: :auto)
    end

    test "negative byte_range start" do
      assert {:error, :einval} = StreamOptions.apply("x", byte_range: {-1, 5})
    end

    test "non-integer line_range last" do
      assert {:error, :einval} = StreamOptions.apply("a\nb\n", line_range: {1, :nope})
    end
  end

  describe "apply/2 always returns a clean shape" do
    property "for any content + any opts, returns {:ok, stream} or {:error, :einval}" do
      check all content <- binary(max_length: 100),
                opts <- random_opts(),
                max_runs: 100 do
        case StreamOptions.apply(content, opts) do
          {:ok, stream} ->
            # Stream consumes to a binary; never crashes.
            assert is_binary(stream |> Enum.to_list() |> IO.iodata_to_binary())

          {:error, :einval} ->
            :ok

          other ->
            flunk("unexpected return: #{inspect(other)} for opts #{inspect(opts)}")
        end
      end
    end
  end

  defp random_opts do
    list_of(
      one_of([
        tuple({constant(:chunk_size), one_of([integer(-100..100), constant(:bad)])}),
        tuple({constant(:byte_range), tuple({integer(-50..200), integer(-50..200)})}),
        tuple({constant(:line_range), tuple({integer(-10..20), integer(-10..20)})})
      ]),
      max_length: 3
    )
  end
end
