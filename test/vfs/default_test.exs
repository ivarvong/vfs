defmodule VFS.DefaultTest do
  @moduledoc """
  Direct tests for `VFS.Default.walk/3` covering edge cases and error
  paths that aren't naturally exercised through the conformance suite.
  """
  use ExUnit.Case, async: true

  test "walk on a non-existent root yields an empty stream" do
    fs = VFS.Memory.new()
    assert VFS.Default.walk(fs, "/does/not/exist", []) |> Enum.to_list() == []
  end

  test "walk skips subtrees whose readdir fails (continues, doesn't crash)" do
    fs = VFS.Test.UnreadableDir.new()

    # Even though `/borked` reports as a directory, its readdir errors;
    # walk silently continues.
    paths = VFS.Default.walk(fs, "/", []) |> Enum.map(&elem(&1, 0))
    assert "/ok" in paths
    refute Enum.any?(paths, &String.starts_with?(&1, "/borked/"))
  end
end
