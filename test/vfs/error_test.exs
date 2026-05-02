defmodule VFS.ErrorTest do
  use ExUnit.Case, async: true

  doctest VFS.Error

  describe "exception/1" do
    test "constructs with default message" do
      err = VFS.Error.exception(kind: :enoent, path: "/foo")
      assert err.kind == :enoent
      assert err.path == "/foo"
      assert err.message == ":enoent at /foo"
    end

    test "honors a passed-in :message" do
      err = VFS.Error.exception(kind: :enoent, path: "/foo", message: "custom")
      assert err.message == "custom"
    end

    test "kind without path produces a kind-only message" do
      err = VFS.Error.exception(kind: :eio)
      assert err.message == ":eio"
    end
  end

  describe "Exception.message/1" do
    test "returns the stored message when present" do
      err = VFS.Error.exception(kind: :enoent, path: "/x")
      assert Exception.message(err) == ":enoent at /x"
    end

    test "derives a message when :message is nil" do
      err = %VFS.Error{kind: :enoent, path: "/y"}
      assert Exception.message(err) == ":enoent at /y"
    end

    test "derives a kind-only message when both :message and :path are nil" do
      err = %VFS.Error{kind: :eio}
      assert Exception.message(err) == ":eio"
    end
  end

  describe "raisable" do
    test "can be raised with kind and path" do
      assert_raise VFS.Error, ":enoent at /foo", fn ->
        raise VFS.Error, kind: :enoent, path: "/foo"
      end
    end
  end

  describe "new/2 + put_mount/2" do
    test "new/2 builds without raising" do
      err = VFS.Error.new(:eisdir, path: "/d")
      assert %VFS.Error{kind: :eisdir, path: "/d"} = err
    end

    test "put_mount/2 attaches mount context" do
      err = VFS.Error.new(:enoent, path: "/x") |> VFS.Error.put_mount("/mount")
      assert err.mount == "/mount"
    end
  end
end
