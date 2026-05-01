defmodule VFS.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/ivarvong/vfs"

  def project do
    [
      app: :vfs,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      elixirc_options: [warnings_as_errors: true],
      consolidate_protocols: Mix.env() != :test,
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

  def application do
    [extra_applications: [:logger]]
  end

  def cli do
    [
      preferred_envs: [
        check: :test,
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test,
        "coveralls.json": :test,
        "coveralls.post": :test,
        dialyzer: :dev
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:telemetry, "~> 1.3"},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:benchee, "~> 1.3", only: :dev, runtime: false}
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
