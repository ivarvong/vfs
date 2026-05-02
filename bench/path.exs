# `VFS.Path.normalize/1` is the single hottest function in the library —
# every public op normalizes its path argument. Worth knowing the cost.
#
#     mix run bench/path.exs

inputs = %{
  "root" => "/",
  "shallow" => "/foo",
  "typical (5 segs)" => "/a/b/c/d/e",
  "deep (20 segs)" =>
    "/a/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p/q/r/s/t",
  "needs collapse" => "/a/./b/../c/d/e",
  "many redundancies" => "//a//./b/../c/./../d/./e/."
}

Benchee.run(
  %{
    "VFS.Path.normalize/1" => fn input -> VFS.Path.normalize(input) end
  },
  inputs: inputs,
  warmup: 1,
  time: 2,
  print: [fast_warning: false]
)
