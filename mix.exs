System.put_env("MIX_OS_CONCURRENCY_LOCK", "0")

defmodule ThreeChess.MixProject do
  use Mix.Project

  def project do
    [
      app: :three_chess,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    []
  end
end
