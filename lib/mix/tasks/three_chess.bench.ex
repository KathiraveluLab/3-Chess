defmodule Mix.Tasks.ThreeChess.Bench do
  @moduledoc "Runs 96-cell Perft, sudden-elimination verification, and AI benchmarks."
  use Mix.Task

  @shortdoc "Run 3-Chess Perft and AI benchmarks"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("compile")
    ThreeChess.Benchmark.run()
  end
end
