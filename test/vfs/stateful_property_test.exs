defmodule VFS.StatefulPropertyTest do
  @moduledoc """
  Stateful property tests: random sequences of filesystem operations are
  applied to both `VFS.Memory` and a `VFS.Test.Model` reference; any
  divergence is a real bug in the impl. StreamData shrinks failures to
  minimal failing sequences.

  This is the test that catches order-dependent bugs no individual unit
  test will find — write, then mkdir on an implicit dir, then rm, then
  re-write, then walk. Unit tests verify each step in isolation; this
  property verifies the *interaction* between steps over arbitrary
  histories.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias VFS.Test.Model

  # Bounded path universe so generated sequences exercise the same paths
  # repeatedly (with overwrites, removes, mkdir-on-existing-dir, etc.).
  @paths [
    "/a",
    "/b",
    "/c",
    "/d/x",
    "/d/y",
    "/d/sub/z",
    "/e/f/g",
    "/e/f/h",
    "/dir1",
    "/dir1/inner"
  ]

  property "any sequence of write/rm/mkdir leaves observable state matching the model" do
    check all ops <- list_of(operation(), min_length: 1, max_length: 30),
              max_runs: 200 do
      {fs, model} = run(ops)

      # Compare observables across every path in the universe — catches
      # divergences that didn't manifest as op-result mismatches.
      for p <- @paths do
        compare_read(fs, model, p)
        compare_exists(fs, model, p)
        compare_stat(fs, model, p)
      end

      # Walk equivalence: the set of regular file paths walking yields
      # must match the model's set.
      walked = fs |> VFS.Mountable.walk("/", []) |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      assert walked == Model.all_files(model)
    end
  end

  # ── op application ──────────────────────────────────────────────────────

  defp run(ops) do
    Enum.reduce(ops, {VFS.Memory.new(), Model.new()}, fn op, {fs, model} ->
      apply_op(fs, model, op)
    end)
  end

  defp apply_op(fs, model, {:write, path, content}) do
    impl_result = VFS.Mountable.write_file(fs, path, content, [])
    model_result = Model.write(model, path, content)
    converge(fs, model, impl_result, model_result, op_label(:write, path))
  end

  defp apply_op(fs, model, {:rm, path, recursive?}) do
    impl_result = VFS.Mountable.rm(fs, path, recursive: recursive?)
    model_result = Model.rm(model, path, recursive?)
    converge(fs, model, impl_result, model_result, op_label(:rm, path))
  end

  defp apply_op(fs, model, {:mkdir, path, parents?}) do
    impl_result = VFS.Mountable.mkdir(fs, path, parents: parents?)
    model_result = Model.mkdir(model, path, parents?)
    converge(fs, model, impl_result, model_result, op_label(:mkdir, path))
  end

  # ── op-by-op convergence ────────────────────────────────────────────────

  defp converge(fs, model, impl_result, model_result, label) do
    case {impl_result, model_result} do
      {{:ok, fs2}, {:ok, model2}} ->
        {fs2, model2}

      {{:error, %VFS.Error{kind: kind}}, {:error, kind}} ->
        # Both failed with the same kind — state unchanged in both.
        {fs, model}

      {a, b} ->
        flunk("divergence on #{label}\n  impl:  #{inspect(a)}\n  model: #{inspect(b)}")
    end
  end

  # ── observable comparisons ──────────────────────────────────────────────

  defp compare_read(fs, model, path) do
    case {VFS.Mountable.stream_read(fs, path, []), Model.read(model, path)} do
      {{:ok, stream, _fs2}, {:ok, content}} ->
        actual = stream |> Enum.to_list() |> IO.iodata_to_binary()

        assert actual == content,
               "read divergence on #{path}: impl=#{inspect(actual)} model=#{inspect(content)}"

      {{:error, %VFS.Error{kind: k}}, {:error, k}} ->
        :ok

      {a, b} ->
        flunk("read divergence on #{path}\n  impl:  #{inspect(a)}\n  model: #{inspect(b)}")
    end
  end

  defp compare_exists(fs, model, path) do
    {actual, _} = VFS.Mountable.exists?(fs, path)
    expected = Model.exists?(model, path)

    assert actual == expected,
           "exists?/2 divergence on #{path}: impl=#{actual} model=#{expected}"
  end

  defp compare_stat(fs, model, path) do
    case {VFS.Mountable.stat(fs, path), Model.stat_type(model, path)} do
      {{:ok, %VFS.Stat{type: t}, _fs2}, {:ok, t}} ->
        :ok

      {{:error, %VFS.Error{kind: :enoent}}, {:error, :enoent}} ->
        :ok

      {a, b} ->
        flunk("stat divergence on #{path}\n  impl:  #{inspect(a)}\n  model: #{inspect(b)}")
    end
  end

  # ── op generators ───────────────────────────────────────────────────────

  defp operation do
    one_of([
      tuple({constant(:write), member_of(@paths), binary(max_length: 16)}),
      tuple({constant(:rm), member_of(@paths), boolean()}),
      tuple({constant(:mkdir), member_of(@paths), boolean()})
    ])
  end

  defp op_label(verb, path), do: "#{verb} #{path}"
end
