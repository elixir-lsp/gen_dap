defmodule GenDAP.MixProject do
  use Mix.Project

  @source_url "https://github.com/elixir-lsp/gen_dap"

  def project do
    [
      app: :gen_dap,
      description: "Library for creating debug adapters",
      source_url: @source_url,
      version: "0.0.1",
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      docs: docs(),
      package: package(),
      dialyzer: [
        plt_add_apps: [:ex_unit]
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_doc, ">= 0.0.0", only: :dev},
      {:typed_struct, "~> 0.3"},
      {:jason, "~> 1.3", optional: true},
      {:nimble_options, "~> 0.5 or ~> 1.0"},
      # {:schematic, path: "../schematic"},
      {:schematic, "~> 0.2"},
      {:dialyxir, ">= 0.0.0", only: [:dev, :test], runtime: false}
    ] ++ spec_lint_deps()
  end

  # spec_lint requires Elixir ~> 1.18
  defp spec_lint_deps do
    if Version.match?(System.version(), ">= 1.18.0") do
      [{:spec_lint, "~> 0.1", only: [:dev, :test], runtime: false}]
    else
      []
    end
  end

  defp docs() do
    [
      main: "GenDAP",
      nest_modules_by_prefix: [
        "GenDAP.Requests",
        "GenDAP.Notifications",
        "GenDAP.Enumerations",
        "GenDAP.Structures"
      ]
    ]
  end

  defp package() do
    [
      maintainers: ["Łukasz Samson"],
      licenses: ["MIT"],
      links: %{
        GitHub: @source_url,
        Sponsor: "https://github.com/sponsors/lukaszsamson"
      },
      files: ~w(lib LICENSE mix.exs README.md .formatter.exs)
    ]
  end
end
