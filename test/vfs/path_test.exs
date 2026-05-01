defmodule VFS.PathTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest VFS.Path

  describe "normalize/1" do
    test "raises on non-absolute input" do
      assert_raise ArgumentError, ~r/absolute/, fn -> VFS.Path.normalize("foo") end
      assert_raise ArgumentError, ~r/absolute/, fn -> VFS.Path.normalize("") end
    end

    test "collapses redundant separators" do
      assert VFS.Path.normalize("////") == "/"
      assert VFS.Path.normalize("/foo//bar") == "/foo/bar"
    end

    test "resolves .. past root as a no-op" do
      assert VFS.Path.normalize("/../../foo") == "/foo"
    end
  end

  describe "absolute?/1" do
    test "matches paths with leading slash" do
      assert VFS.Path.absolute?("/")
      assert VFS.Path.absolute?("/foo")
      refute VFS.Path.absolute?("foo")
      refute VFS.Path.absolute?("")
    end
  end

  describe "split/1" do
    test "drops empty segments and the leading slash" do
      assert VFS.Path.split("/foo/bar") == ["foo", "bar"]
      assert VFS.Path.split("/") == []
    end
  end

  describe "join/2" do
    test "concatenates relative paths" do
      assert VFS.Path.join("/foo", "bar/baz") == "/foo/bar/baz"
    end

    test "handles trailing slash on base" do
      assert VFS.Path.join("/foo/", "bar") == "/foo/bar"
    end

    test "absolute second arg wins" do
      assert VFS.Path.join("/anything", "/abs") == "/abs"
    end

    test "join from root" do
      assert VFS.Path.join("/", "foo") == "/foo"
    end
  end

  describe "dirname/1 and basename/1" do
    test "complement each other for typical paths" do
      assert VFS.Path.dirname("/a/b/c") == "/a/b"
      assert VFS.Path.basename("/a/b/c") == "c"
    end

    test "root edge cases" do
      assert VFS.Path.dirname("/") == "/"
      assert VFS.Path.basename("/") == ""
    end
  end

  describe "relative_to/2" do
    test "returns sub-path under the new root" do
      assert VFS.Path.relative_to("/a/b/c", "/a") == {:ok, "/b/c"}
    end

    test "exact match returns root" do
      assert VFS.Path.relative_to("/a", "/a") == {:ok, "/"}
    end

    test "non-prefix returns :error" do
      assert VFS.Path.relative_to("/abc", "/ab") == :error
    end

    test "/ is the prefix of everything" do
      assert VFS.Path.relative_to("/anywhere", "/") == {:ok, "/anywhere"}
    end
  end

  describe "properties" do
    property "normalize is idempotent" do
      check all p <- random_absolute_path(), max_runs: 200 do
        once = VFS.Path.normalize(p)
        twice = VFS.Path.normalize(once)
        assert once == twice
      end
    end

    property "normalize always returns absolute" do
      check all p <- random_absolute_path(), max_runs: 200 do
        assert VFS.Path.absolute?(VFS.Path.normalize(p))
      end
    end

    property "join . normalize equals normalize . join" do
      check all base <- normalized_path(),
                rel <- relative_path(),
                max_runs: 100 do
        assert VFS.Path.normalize(VFS.Path.join(base, rel)) == VFS.Path.join(base, rel)
      end
    end

    property "relative_to roundtrips with join when prefix matches" do
      check all base <- normalized_path(),
                tail_segs <- list_of(member_of(["a", "b", "c"]), min_length: 0, max_length: 3),
                max_runs: 100 do
        full =
          if tail_segs == [] do
            base
          else
            VFS.Path.join(base, Enum.join(tail_segs, "/"))
          end

        assert {:ok, sub} = VFS.Path.relative_to(full, base)
        assert VFS.Path.join(base, String.trim_leading(sub, "/")) == full
      end
    end
  end

  defp random_absolute_path do
    list_of(
      member_of(["foo", "bar", "baz", ".", "..", "x", "y"]),
      min_length: 0,
      max_length: 6
    )
    |> map(fn parts -> "/" <> Enum.join(parts, "/") end)
  end

  defp normalized_path do
    list_of(member_of(["foo", "bar", "baz"]), min_length: 0, max_length: 4)
    |> map(fn parts -> "/" <> Enum.join(parts, "/") end)
    |> map(&VFS.Path.normalize/1)
  end

  defp relative_path do
    list_of(member_of(["a", "b", "c", ".", ".."]), min_length: 0, max_length: 3)
    |> map(&Enum.join(&1, "/"))
  end
end
