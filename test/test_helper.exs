# Load .env if present (dev/local). CI should inject these via secrets,
# so missing .env is not an error. Mirrors deps/exgit/test/test_helper.exs.
env_file = Path.join(__DIR__, "../.env") |> Path.expand()

if File.exists?(env_file) do
  for line <- File.read!(env_file) |> String.split("\n", trim: true),
      not String.starts_with?(line, "#") do
    case String.split(line, "=", parts: 2) do
      [k, v] ->
        key = k |> String.trim_leading("export ") |> String.trim()
        val = v |> String.trim() |> String.trim(~s(")) |> String.trim(~s('))
        System.put_env(key, val)

      _ ->
        :ok
    end
  end
end

# Self-hosted-testing workaround. exgit ships a `defimpl VFS.Mountable,
# for: Exgit.Workspace` guarded by `Code.ensure_loaded?(VFS.Mountable)`.
# Mix builds deps before the host project's lib, so when exgit was
# compiled, `VFS.Mountable.beam` didn't yet exist and the defimpl was
# skipped. By now (test_helper load time) both modules ARE loaded, so
# we compile the file in place. Downstream consumers don't need this —
# mix orders vfs before exgit via the optional edge in exgit/mix.exs.
unless Code.ensure_loaded?(Exgit.Workspace.VFS) do
  workspace_vfs = "deps/exgit/lib/exgit/workspace/vfs.ex"
  if File.exists?(workspace_vfs), do: Code.compile_file(workspace_vfs)
end

ExUnit.start(exclude: [:integration, :integration_network, :known_limitation])
