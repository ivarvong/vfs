defmodule VFS.StatTest do
  use ExUnit.Case, async: true

  doctest VFS.Stat

  test "regular/3 builds a regular stat" do
    now = DateTime.utc_now()
    stat = VFS.Stat.regular(42, now)

    assert stat.type == :regular
    assert stat.size == 42
    assert stat.mtime == now
    assert stat.mode == nil
  end

  test "regular/3 carries mode if given" do
    stat = VFS.Stat.regular(0, DateTime.utc_now(), 0o644)
    assert stat.mode == 0o644
  end

  test "directory/2 builds a directory stat with size 0" do
    now = DateTime.utc_now()
    stat = VFS.Stat.directory(now)

    assert stat.type == :directory
    assert stat.size == 0
    assert stat.mtime == now
  end

  test "@enforce_keys requires type, size, mtime" do
    assert_raise ArgumentError, fn ->
      struct!(VFS.Stat, type: :regular, size: 0)
    end
  end
end
