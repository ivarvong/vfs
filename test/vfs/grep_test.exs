defmodule VFS.GrepTest do
  use ExUnit.Case, async: true

  describe "VFS.grep/4" do
    test "matches lines across multiple files" do
      fs =
        VFS.new(%{
          "/a.ex" => "todo: x\nok\nTODO y\n",
          "/b.ex" => "fine\n",
          "/sub/c.ex" => "TODO from sub\nokay"
        })

      results = fs |> VFS.grep("/", ~r/TODO/i) |> Enum.to_list()

      paths = results |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()
      assert paths == ["/a.ex", "/sub/c.ex"]
    end

    test "no matches returns empty stream" do
      fs = VFS.new(%{"/a" => "fine\nokay\n"})
      assert fs |> VFS.grep("/", ~r/never/) |> Enum.to_list() == []
    end

    test "returns {path, line_number, line} tuples in order" do
      fs = VFS.new(%{"/a" => "first\nsecond match\nthird\nmatch again\n"})
      results = fs |> VFS.grep("/", ~r/match/) |> Enum.to_list()

      assert results == [
               {"/a", 2, "second match"},
               {"/a", 4, "match again"}
             ]
    end

    test "rooted grep only scans under the root" do
      fs = VFS.new(%{"/in_root" => "match\n", "/sub/in_sub" => "match\n"})
      results = fs |> VFS.grep("/sub", ~r/match/) |> Enum.to_list()
      assert results == [{"/sub/in_sub", 1, "match"}]
    end
  end

  describe "VFS.glob/4" do
    test "matches simple wildcards" do
      fs = VFS.new(%{"/a.ex" => "", "/b.ex" => "", "/c.exs" => ""})
      result = fs |> VFS.glob("/", "*.ex") |> Enum.sort()
      assert result == ["/a.ex", "/b.ex"]
    end

    test "** matches across directories" do
      fs = VFS.new(%{"/a.ex" => "", "/sub/b.ex" => "", "/sub/deep/c.ex" => ""})
      result = fs |> VFS.glob("/", "**/*.ex") |> Enum.sort()
      assert result == ["/a.ex", "/sub/b.ex", "/sub/deep/c.ex"]
    end

    test "? matches a single character" do
      fs = VFS.new(%{"/a.ex" => "", "/aa.ex" => "", "/b.ex" => ""})
      result = fs |> VFS.glob("/", "?.ex") |> Enum.sort()
      assert result == ["/a.ex", "/b.ex"]
    end
  end
end
