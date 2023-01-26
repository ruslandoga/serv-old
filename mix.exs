defmodule Serv.MixProject do
  use Mix.Project

  def project do
    [
      app: :serv,
      version: "0.1.0",
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "dev"]
  defp elixirc_paths(_env), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:plug, "~> 1.14"},
      {:telemetry, "~> 1.2"},
      {:mint, "~> 1.4", only: [:test]},
      {:benchee, "~> 1.1", only: [:bench]},
      {:dialyxir, "~> 1.2", only: [:test, :dev], runtime: false}
    ]
  end
end
