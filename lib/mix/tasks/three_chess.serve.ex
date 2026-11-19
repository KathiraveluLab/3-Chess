defmodule Mix.Tasks.ThreeChess.Serve do
  @moduledoc """
  Starts the 3-Chess HTTP/SSE server for local and LAN multiplayer play.

  Options:
    * `--port` - TCP port to listen on (default: 8080)
    * `--host` - IPv4 bind address (default: 0.0.0.0 for LAN access; pass 127.0.0.1 for local-only)
  """
  use Mix.Task

  @shortdoc "Serve the 3-Chess web interface on the local network (default 0.0.0.0:8080)"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("compile")

    {parsed, _rest, _invalid} =
      OptionParser.parse(args, strict: [port: :integer, host: :string])

    port = Keyword.get(parsed, :port, 8080)
    host = Keyword.get(parsed, :host, "0.0.0.0")

    ThreeChess.HttpServer.start(port, "web", host: host)
  end
end
