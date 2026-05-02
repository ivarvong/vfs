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

  describe "fuzz / adversarial properties" do
    @moduletag :fuzz

    property "normalize never crashes on arbitrary UTF-8 input starting with /" do
      check all rest <- string(:utf8, max_length: 200),
                max_runs: 1_000 do
        result = VFS.Path.normalize("/" <> rest)
        assert is_binary(result)
        assert String.starts_with?(result, "/")
      end
    end

    property "normalize never crashes on arbitrary printable ASCII starting with /" do
      check all rest <- string(:printable, max_length: 200),
                max_runs: 1_000 do
        result = VFS.Path.normalize("/" <> rest)
        assert is_binary(result)
        assert String.starts_with?(result, "/")
      end
    end

    property "normalized output never contains . or .. segments" do
      # Security invariant. If a malicious caller passes /../../etc/passwd,
      # the normalized form must not retain any .. that consumers might
      # interpret as parent traversal.
      check all parts <-
                  list_of(member_of(["foo", "..", ".", "bar", "x", "y", ""]),
                    min_length: 0,
                    max_length: 30
                  ),
                max_runs: 500 do
        n = VFS.Path.normalize("/" <> Enum.join(parts, "/"))
        segs = String.split(n, "/", trim: true)

        refute Enum.any?(segs, &(&1 in [".", ".."])),
               "found . or .. in #{n} from input parts #{inspect(parts)}"
      end
    end

    property "output never escapes root regardless of how many .. are in the input" do
      check all dotdot_count <- integer(0..50),
                tail <- list_of(member_of(["foo", "bar"]), min_length: 0, max_length: 5),
                max_runs: 200 do
        prefix = String.duplicate("../", dotdot_count)
        suffix = Enum.join(tail, "/")
        n = VFS.Path.normalize("/" <> prefix <> suffix)
        assert String.starts_with?(n, "/")
        # Whatever the depth of `..`, the result must be `/` + the tail or shallower.
        assert String.split(n, "/", trim: true) |> length() <= length(tail)
      end
    end

    property "normalize length cannot exceed input length (no unbounded expansion)" do
      check all rest <- string(:printable, max_length: 200), max_runs: 500 do
        n = VFS.Path.normalize("/" <> rest)
        assert byte_size(n) <= byte_size("/" <> rest) + 1
      end
    end

    property "normalize always rejects non-absolute input via ArgumentError" do
      check all bad <- one_of([constant(""), string(:printable, max_length: 50)]),
                # explicitly remove cases that start with /
                not String.starts_with?(bad, "/"),
                max_runs: 500 do
        assert_raise ArgumentError, fn -> VFS.Path.normalize(bad) end
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
