defmodule ThreeChess.HttpServer do
  @moduledoc """
  Zero-dependency HTTP server built over :gen_tcp for serving the 3-Chess web
  interface and JSON game API.
  """

  alias ThreeChess.GameServer

  @spec start(pos_integer(), String.t()) :: no_return()
  def start(port \\ 8080, web_dir \\ "web") do
    case GameServer.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    {:ok, listen_socket} =
      :gen_tcp.listen(port, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    IO.puts("3-Chess server listening on http://127.0.0.1:#{port}/")
    accept_loop(listen_socket, web_dir)
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
      {:ok, method, path, body} ->
        {status, content_type, resp_body} = route(method, path, body, web_dir)
        send_response(socket, status, content_type, resp_body)

      :error ->
        send_response(socket, "400 Bad Request", "text/plain", "Bad Request")
    end

    :gen_tcp.close(socket)
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
            String.trim(v) |> String.to_integer()
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

  defp route("GET", "/api/state", _body, _web_dir) do
    {"200 OK", "application/json; charset=utf-8", JSON.encode!(GameServer.get_payload())}
  end

  defp route("POST", "/api/reset", _body, _web_dir) do
    {"200 OK", "application/json; charset=utf-8", JSON.encode!(GameServer.reset())}
  end

  defp route("POST", "/api/demo", _body, _web_dir) do
    {"200 OK", "application/json; charset=utf-8", JSON.encode!(GameServer.load_demo())}
  end

  defp route("POST", "/api/move", body, _web_dir) do
    case JSON.decode(body) do
      {:ok, %{"from" => from, "to" => to} = params} when is_integer(from) and is_integer(to) ->
        promo = Map.get(params, "promo", 0)
        res = GameServer.make_move(from, to, promo)
        {"200 OK", "application/json; charset=utf-8", JSON.encode!(res)}

      _ ->
        {"400 Bad Request", "application/json; charset=utf-8", JSON.encode!(%{ok: false, error: "Invalid move payload"})}
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

    res = GameServer.ai_move(strategy, depth)
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
        "Cache-Control: no-store\r\n" <>
        "Connection: close\r\n\r\n"

    header <> body
  end

  defp send_response(socket, status, content_type, body) do
    :gen_tcp.send(socket, format_response(status, content_type, body))
  end
end
