defmodule ThreeChess.HttpServer do
  @moduledoc """
  Zero-dependency HTTP and Server-Sent Events (SSE) server built over :gen_tcp
  for serving the 3-Chess web interface and LAN multiplayer JSON API.
  """

  alias ThreeChess.GameServer

  @sse_heartbeat_ms 15_000

  @doc "Parses an IPv4 host string such as \"0.0.0.0\" or \"127.0.0.1\" into an Erlang IP tuple."
  @spec parse_host(String.t()) :: {:ok, :inet.ip4_address()} | {:error, :invalid_host}
  def parse_host(host) when is_binary(host) do
    case host |> String.trim() |> String.to_charlist() |> :inet.parse_ipv4_address() do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> {:error, :invalid_host}
    end
  end

  def parse_host(_), do: {:error, :invalid_host}

  @doc "Returns non-loopback, non-link-local IPv4 addresses detected on local network interfaces."
  @spec local_ipv4_addresses() :: [String.t()]
  def local_ipv4_addresses do
    case :inet.getifaddrs() do
      {:ok, ifaddrs} ->
        ifaddrs
        |> Enum.flat_map(fn {_name, opts} ->
          flags = Keyword.get(opts, :flags, [])

          if :up in flags and :loopback not in flags do
            for {:addr, {a, b, c, d}} <- opts,
                a != 127,
                not (a == 169 and b == 254) do
              {lan_priority(a, b), "#{a}.#{b}.#{c}.#{d}"}
            end
          else
            []
          end
        end)
        |> Enum.uniq_by(fn {_prio, ip} -> ip end)
        |> Enum.sort()
        |> Enum.map(fn {_prio, ip} -> ip end)

      {:error, _} ->
        []
    end
  end

  defp lan_priority(192, 168), do: 0
  defp lan_priority(10, _), do: 1
  defp lan_priority(172, b) when b >= 16 and b <= 31, do: 2
  defp lan_priority(_, _), do: 3

  @spec start(pos_integer(), String.t(), keyword()) :: no_return()
  def start(port \\ 9090, web_dir \\ "web", opts \\ []) do
    host_str = Keyword.get(opts, :host, "0.0.0.0")

    ip_tuple =
      case parse_host(host_str) do
        {:ok, ip} -> ip
        {:error, _} -> {0, 0, 0, 0}
      end

    case GameServer.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    lan_urls =
      case ip_tuple do
        {0, 0, 0, 0} ->
          Enum.map(local_ipv4_addresses(), fn ip -> "http://#{ip}:#{port}/" end)

        {127, 0, 0, 1} ->
          []

        {a, b, c, d} ->
          ["http://#{a}.#{b}.#{c}.#{d}:#{port}/"]
      end

    GameServer.set_lan_urls(lan_urls)

    {:ok, listen_socket} =
      :gen_tcp.listen(port, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: ip_tuple
      ])

    print_startup_banner(ip_tuple, port, lan_urls)
    accept_loop(listen_socket, web_dir)
  end

  defp print_startup_banner({0, 0, 0, 0}, port, lan_urls) do
    IO.puts("3-Chess LAN multiplayer server listening on 0.0.0.0:#{port}")
    IO.puts("  Local:   http://127.0.0.1:#{port}/")

    case lan_urls do
      [] ->
        IO.puts("  Network: No active non-loopback IPv4 interface detected")

      urls ->
        Enum.each(urls, fn url ->
          IO.puts("  Network: #{url}")
        end)
    end
  end

  defp print_startup_banner({a, b, c, d}, port, _lan_urls) do
    IO.puts("3-Chess server listening on http://#{a}.#{b}.#{c}.#{d}:#{port}/")
  end

  defp accept_loop(listen_socket, web_dir) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, client} ->
        Task.start(fn -> handle_client(client, web_dir) end)
        accept_loop(listen_socket, web_dir)

      {:error, _reason} ->
        :ok
    end
  end

  defp handle_client(socket, web_dir) do
    case read_http_request(socket, "") do
      {:ok, "GET", "/api/events", _body} ->
        handle_sse(socket)

      {:ok, method, path, body} ->
        {status, content_type, resp_body} = route(method, path, body, web_dir)
        send_response(socket, status, content_type, resp_body)
        :gen_tcp.close(socket)

      :error ->
        send_response(socket, "400 Bad Request", "text/plain", "Bad Request")
        :gen_tcp.close(socket)
    end
  end

  defp handle_sse(socket) do
    headers =
      "HTTP/1.1 200 OK\r\n" <>
        "Content-Type: text/event-stream; charset=utf-8\r\n" <>
        "Cache-Control: no-cache\r\n" <>
        "Connection: keep-alive\r\n" <>
        "Access-Control-Allow-Origin: *\r\n" <>
        "X-Accel-Buffering: no\r\n\r\n"

    initial_payload = GameServer.subscribe(self())
    initial_chunk = "data: " <> JSON.encode!(initial_payload) <> "\n\n"

    case :gen_tcp.send(socket, [headers, initial_chunk]) do
      :ok ->
        sse_loop(socket)

      {:error, _} ->
        :ok
    end

    GameServer.unsubscribe(self())
    :gen_tcp.close(socket)
  end

  defp sse_loop(socket) do
    receive do
      {:three_chess_event, encoded_json} ->
        case :gen_tcp.send(socket, ["data: ", encoded_json, "\n\n"]) do
          :ok -> sse_loop(socket)
          {:error, _} -> :ok
        end
    after
      @sse_heartbeat_ms ->
        case :gen_tcp.send(socket, ": keepalive\n\n") do
          :ok -> sse_loop(socket)
          {:error, _} -> :ok
        end
    end
  end

  @doc "Processes a raw HTTP/1.1 request buffer and returns the full HTTP response binary."
  @spec process_raw_request(binary(), String.t()) :: binary()
  def process_raw_request(raw_request, web_dir \\ "web") do
    case parse_request_parts(raw_request) do
      {:ok, method, path, _cl, body} ->
        {status, content_type, resp_body} = route(method, path, body, web_dir)
        format_response(status, content_type, resp_body)

      :error ->
        format_response("400 Bad Request", "text/plain", "Bad Request")
    end
  end

  defp parse_request_parts(buf) do
    case :binary.match(buf, "\r\n\r\n") do
      {pos, 4} ->
        header_part = binary_part(buf, 0, pos)
        rest = binary_part(buf, pos + 4, byte_size(buf) - pos - 4)
        lines = String.split(header_part, "\r\n")
        [req_line | header_lines] = lines

        case String.split(req_line, " ") do
          [method, raw_path | _] ->
            path = raw_path |> String.split("?") |> hd()
            cl = parse_content_length(header_lines)
            {:ok, method, path, cl, rest}

          _ ->
            :error
        end

      :nomatch ->
        :error
    end
  end

  defp read_http_request(socket, buf) do
    case parse_request_parts(buf) do
      {:ok, method, path, cl, rest} ->
        body = read_exact_body(socket, rest, cl)
        {:ok, method, path, body}

      :error ->
        if :binary.match(buf, "\r\n\r\n") != :nomatch do
          :error
        else
          case :gen_tcp.recv(socket, 0, 5_000) do
            {:ok, chunk} -> read_http_request(socket, buf <> chunk)
            {:error, _} -> :error
          end
        end
    end
  end

  defp parse_content_length(headers) do
    Enum.find_value(headers, 0, fn h ->
      case String.split(h, ":", parts: 2) do
        [k, v] ->
          if String.downcase(String.trim(k)) == "content-length" do
            case Integer.parse(String.trim(v)) do
              {n, _} when n >= 0 -> n
              _ -> 0
            end
          end

        _ ->
          nil
      end
    end)
  end

  defp read_exact_body(_socket, acc, target) when byte_size(acc) >= target do
    binary_part(acc, 0, target)
  end

  defp read_exact_body(socket, acc, target) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, chunk} -> read_exact_body(socket, acc <> chunk, target)
      {:error, _} -> acc
    end
  end

  defp route("OPTIONS", _path, _body, _web_dir) do
    {"204 No Content", "text/plain; charset=utf-8", ""}
  end

  defp route("GET", "/api/state", _body, _web_dir) do
    {"200 OK", "application/json; charset=utf-8", JSON.encode!(GameServer.get_payload())}
  end

  defp route("POST", "/api/reset", _body, _web_dir) do
    {"200 OK", "application/json; charset=utf-8", JSON.encode!(GameServer.reset())}
  end

  defp route("POST", "/api/demo", _body, _web_dir) do
    {"200 OK", "application/json; charset=utf-8", JSON.encode!(GameServer.load_demo())}
  end

  defp route("POST", "/api/seat", body, _web_dir) do
    case JSON.decode(body) do
      {:ok, %{"action" => "claim", "player" => player, "client_id" => client_id} = params}
      when is_integer(player) and is_binary(client_id) ->
        res = GameServer.claim_seat(player, client_id, Map.get(params, "name"))
        {"200 OK", "application/json; charset=utf-8", JSON.encode!(res)}

      {:ok, %{"action" => "release", "player" => player} = params} when is_integer(player) ->
        client_id = Map.get(params, "client_id")
        force = Map.get(params, "force", false) == true
        res = GameServer.release_seat(player, client_id, force)
        {"200 OK", "application/json; charset=utf-8", JSON.encode!(res)}

      {:ok, %{"action" => "controller", "player" => player, "controller" => controller}}
      when is_integer(player) and is_binary(controller) ->
        res = GameServer.set_controller(player, controller)
        {"200 OK", "application/json; charset=utf-8", JSON.encode!(res)}

      _ ->
        {"400 Bad Request", "application/json; charset=utf-8",
         JSON.encode!(%{ok: false, error: "Invalid seat request payload"})}
    end
  end

  defp route("POST", "/api/move", body, _web_dir) do
    case JSON.decode(body) do
      {:ok, %{"from" => from, "to" => to} = params} when is_integer(from) and is_integer(to) ->
        promo = Map.get(params, "promo", 0)
        client_id = Map.get(params, "client_id")
        res = GameServer.make_move(from, to, promo, client_id)
        {"200 OK", "application/json; charset=utf-8", JSON.encode!(res)}

      _ ->
        {"400 Bad Request", "application/json; charset=utf-8",
         JSON.encode!(%{ok: false, error: "Invalid move payload"})}
    end
  end

  defp route("POST", "/api/ai_move", body, _web_dir) do
    params =
      case JSON.decode(body) do
        {:ok, map} when is_map(map) -> map
        _ -> %{}
      end

    strategy =
      case Map.get(params, "strategy", "paranoid") do
        "maxn" -> :maxn
        _ -> :paranoid
      end

    depth =
      case Map.get(params, "depth", 2) do
        d when is_integer(d) -> min(max(d, 1), 3)
        _ -> 2
      end

    expected_ply =
      case Map.get(params, "expected_ply") do
        p when is_integer(p) -> p
        _ -> nil
      end

    res = GameServer.ai_move(strategy, depth, expected_ply)
    {"200 OK", "application/json; charset=utf-8", JSON.encode!(res)}
  end

  defp route("GET", path, _body, web_dir) do
    rel =
      case path do
        "/" -> "index.html"
        "/style.css" -> "style.css"
        "/app.js" -> "app.js"
        "/3chess.wasm" -> "3chess.wasm"
        _ -> nil
      end

    if rel do
      full = Path.join(web_dir, rel)

      case File.read(full) do
        {:ok, content} ->
          {"200 OK", mime_type(rel), content}

        {:error, _} ->
          {"404 Not Found", "text/plain; charset=utf-8", "Not Found"}
      end
    else
      {"404 Not Found", "text/plain; charset=utf-8", "Not Found"}
    end
  end

  defp route(_method, _path, _body, _web_dir) do
    {"404 Not Found", "text/plain; charset=utf-8", "Not Found"}
  end

  defp mime_type("index.html"), do: "text/html; charset=utf-8"
  defp mime_type("style.css"), do: "text/css; charset=utf-8"
  defp mime_type("app.js"), do: "application/javascript; charset=utf-8"
  defp mime_type("3chess.wasm"), do: "application/wasm"
  defp mime_type(_), do: "application/octet-stream"

  defp format_response(status, content_type, body) do
    header =
      "HTTP/1.1 #{status}\r\n" <>
        "Content-Type: #{content_type}\r\n" <>
        "Content-Length: #{byte_size(body)}\r\n" <>
        "Access-Control-Allow-Origin: *\r\n" <>
        "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n" <>
        "Access-Control-Allow-Headers: Content-Type\r\n" <>
        "Cache-Control: no-store\r\n" <>
        "Connection: close\r\n\r\n"

    header <> body
  end

  defp send_response(socket, status, content_type, body) do
    :gen_tcp.send(socket, format_response(status, content_type, body))
  end
end
