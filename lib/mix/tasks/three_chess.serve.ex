defmodule Mix.Tasks.ThreeChess.Serve do
  @moduledoc "Starts the local 3-Chess HTTP server and game engine."
  use Mix.Task

  @shortdoc "Serve the 3-Chess web interface on http://127.0.0.1:8080"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("compile")

    port =
      case OptionParser.parse(args, strict: [port: :integer]) do
        {[port: p], _, _} -> p
        _ -> 8080
      end

    ThreeChess.HttpServer.start(port, "web")
  end
end
