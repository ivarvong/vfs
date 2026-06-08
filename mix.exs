defmodule VFS.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/ivarvong/vfs"

  def project do
    [
      app: :vfs,
      version: @version,
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      consolidate_protocols: consolidate_protocols?(),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      test_coverage: [tool: ExCoveralls],
      dialyzer: [
        plt_add_apps: [:ex_unit, :stream_data, :mix],
        plt_core_path: "priv/plts",
        plt_local_path: "priv/plts",
        flags: [
          :error_handling,
          :unknown,
          :unmatched_returns,
          :extra_return,
          :missing_return
        ]
      ],
      package: package(),
      description: description(),
      docs: docs(),
      name: "VFS",
      source_url: @source_url
    ]
  end

  # Consolidate protocols everywhere except :test (the suite defines its own
  # VFS.Mountable impls), unless VFS_CONSOLIDATE_PROTOCOLS overrides it — CI sets
  # it to prove release-style consolidation doesn't break protocol dispatch.
  defp consolidate_protocols? do
    case System.get_env("VFS_CONSOLIDATE_PROTOCOLS") do
      "true" -> true
      "false" -> false
      _ -> Mix.env() != :test
    end
  end

  # `dev/` holds maintainer-only Mix tasks (vfs.audit, vfs.mutate); it is
  # compiled in dev/test but never shipped (see package `files:`), so consumers
  # don't get internal tooling injected into their projects.
  defp elixirc_paths(:dev), do: ["lib", "dev"]
  defp elixirc_paths(:test), do: ["lib", "test/support", "dev"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:telemetry, "~> 1.3"},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:benchee, "~> 1.3", only: [:dev, :test], runtime: false},

      # Test-only: real exgit for the integration test set. Validates that
      # VFS.Mountable actually fits a non-trivial real-world backend (lazy
      # partial-clone, content-addressed objects, network transports). The
      # defimpl ships in test/support/ for now; production version moves
      # into :exgit once the protocol shape is stable.
      {:exgit, github: "ivarvong/exgit", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "dialyzer --plt"],
      check: [
        "format --check-formatted",
        "compile --warnings-as-errors --force",
        "credo",
        "dialyzer",
        "coveralls --raise"
      ]
    ]
  end

  defp description do
    "Protocol-based virtual filesystem for the Elixir AI tools stack — pluggable backends, " <>
      "state threading, lazy reads, and a tiny core surface."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md SPEC.md CHANGELOG.md LICENSE .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md", "SPEC.md", "CHANGELOG.md"],
      groups_for_modules: [
        Core: [VFS, VFS.Mountable, VFS.Stat, VFS.Path],
        "Backends & helpers": [VFS.Memory, VFS.Skeleton, VFS.Default]
      ]
    ]
  end
end
