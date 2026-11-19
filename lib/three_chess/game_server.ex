defmodule ThreeChess.GameServer do
  @moduledoc """
  OTP GenServer holding the active 3-Chess match state, LAN multiplayer seat
  assignments, real-time SSE subscribers, and AI search telemetry.
  """

  use GenServer
  alias ThreeChess.{AI, Board, MoveGen, Topology}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  def get_payload, do: GenServer.call(__MODULE__, :get_payload)
  def reset, do: GenServer.call(__MODULE__, :reset)
  def load_demo, do: GenServer.call(__MODULE__, :load_demo)

  def make_move(from, to, promo \\ 0, client_id \\ nil) do
    GenServer.call(__MODULE__, {:make_move, from, to, promo, client_id})
  end

  def ai_move(strategy \\ :paranoid, depth \\ 2, expected_ply \\ nil) do
    GenServer.call(__MODULE__, {:ai_move, strategy, depth, expected_ply}, 30_000)
  end

  def claim_seat(player, client_id, name \\ nil) do
    GenServer.call(__MODULE__, {:claim_seat, player, client_id, name})
  end

  def release_seat(player, client_id \\ nil, force \\ false) do
    GenServer.call(__MODULE__, {:release_seat, player, client_id, force})
  end

  def set_controller(player, controller) do
    GenServer.call(__MODULE__, {:set_controller, player, controller})
  end

  def set_lan_urls(urls) when is_list(urls) do
    GenServer.call(__MODULE__, {:set_lan_urls, urls})
  end

  def subscribe(pid) when is_pid(pid) do
    GenServer.call(__MODULE__, {:subscribe, pid})
  end

  def unsubscribe(pid) when is_pid(pid) do
    GenServer.cast(__MODULE__, {:unsubscribe, pid})
  end

  @impl true
  def init(:ok) do
    {:ok,
     %{
       state: Board.new(),
       telemetry: nil,
       version: 1,
       seats: default_seats(),
       lan_urls: [],
       subscribers: %{}
     }}
  end

  defp default_seats do
    %{
      0 => %{controller: "human", client_id: nil, name: nil},
      1 => %{controller: "ai", client_id: nil, name: nil},
      2 => %{controller: "ai", client_id: nil, name: nil}
    }
  end

  @impl true
  def handle_call(:get_payload, _from, data) do
    {:reply, serialize_data(data), data}
  end

  def handle_call(:reset, _from, data) do
    next_data = %{data | state: Board.new(), telemetry: nil, version: data.version + 1}
    payload = broadcast_and_return(next_data)
    {:reply, payload, next_data}
  end

  def handle_call(:load_demo, _from, data) do
    next_data = %{data | state: Board.elimination_demo(), telemetry: nil, version: data.version + 1}
    payload = broadcast_and_return(next_data)
    {:reply, payload, next_data}
  end

  def handle_call({:set_lan_urls, urls}, _from, data) do
    next_data = %{data | lan_urls: urls}
    {:reply, :ok, next_data}
  end

  def handle_call({:subscribe, pid}, _from, data) do
    next_subs =
      if Map.has_key?(data.subscribers, pid) do
        data.subscribers
      else
        ref = Process.monitor(pid)
        Map.put(data.subscribers, pid, ref)
      end

    next_data = %{data | subscribers: next_subs}
    {:reply, serialize_data(next_data), next_data}
  end

  def handle_call({:claim_seat, player, client_id, name}, _from, data)
      when player in 0..2 and is_binary(client_id) and client_id != "" do
    seat = Map.fetch!(data.seats, player)
    clean_name = sanitize_name(name, player)

    cond do
      seat.client_id != nil and seat.client_id != client_id ->
        {:reply,
         %{
           ok: false,
           error: "Seat is already claimed by #{seat.name || "another player"}",
           state: serialize_data(data)
         }, data}

      true ->
        updated_seat = %{controller: "human", client_id: client_id, name: clean_name}
        next_seats = Map.put(data.seats, player, updated_seat)
        next_data = %{data | seats: next_seats, version: data.version + 1}
        payload = broadcast_and_return(next_data)
        {:reply, %{ok: true, state: payload}, next_data}
    end
  end

  def handle_call({:claim_seat, _player, _client_id, _name}, _from, data) do
    {:reply, %{ok: false, error: "Invalid seat claim parameters", state: serialize_data(data)}, data}
  end

  def handle_call({:release_seat, player, client_id, force}, _from, data) when player in 0..2 do
    seat = Map.fetch!(data.seats, player)

    if force or seat.client_id == nil or seat.client_id == client_id do
      updated_seat = %{seat | client_id: nil, name: nil}
      next_seats = Map.put(data.seats, player, updated_seat)
      next_data = %{data | seats: next_seats, version: data.version + 1}
      payload = broadcast_and_return(next_data)
      {:reply, %{ok: true, state: payload}, next_data}
    else
      {:reply,
       %{ok: false, error: "Only the seated player can release this seat", state: serialize_data(data)}, data}
    end
  end

  def handle_call({:release_seat, _player, _client_id, _force}, _from, data) do
    {:reply, %{ok: false, error: "Invalid player seat", state: serialize_data(data)}, data}
  end

  def handle_call({:set_controller, player, controller}, _from, data)
      when player in 0..2 and controller in ["human", "ai"] do
    seat = Map.fetch!(data.seats, player)

    updated_seat =
      if controller == "ai" do
        %{controller: "ai", client_id: nil, name: nil}
      else
        %{seat | controller: "human"}
      end

    next_seats = Map.put(data.seats, player, updated_seat)
    next_data = %{data | seats: next_seats, version: data.version + 1}
    payload = broadcast_and_return(next_data)
    {:reply, %{ok: true, state: payload}, next_data}
  end

  def handle_call({:set_controller, _player, _controller}, _from, data) do
    {:reply, %{ok: false, error: "Invalid controller setting", state: serialize_data(data)}, data}
  end

  def handle_call({:make_move, from, to, promo, client_id}, _from, %{state: state} = data) do
    active_seat = Map.fetch!(data.seats, state.side_to_move)

    cond do
      state.is_game_over ->
        {:reply, %{ok: false, error: "Game is already over", state: serialize_data(data)}, data}

      active_seat.client_id != nil and active_seat.client_id != client_id ->
        owner_label = active_seat.name || Board.player_name(state.side_to_move)

        {:reply,
         %{
           ok: false,
           error: "Seat is controlled by #{owner_label}",
           state: serialize_data(data)
         }, data}

      true ->
        legal = MoveGen.generate_legal_moves(state, state.side_to_move)

        matching =
          Enum.find(legal, fn {mf, mt, mpromo, _mc} ->
            mf == from and mt == to and (mpromo == 0 or promo == 0 or mpromo == promo)
          end)

        case matching do
          nil ->
            {:reply, %{ok: false, error: "Illegal move", state: serialize_data(data)}, data}

          {mf, mt, mpromo, mc} ->
            chosen = if mpromo != 0 and promo == 0, do: {mf, mt, 4, mc}, else: {mf, mt, mpromo, mc}
            next_state = MoveGen.make_move_and_advance(state, chosen, true)
            next_data = %{data | state: next_state, version: data.version + 1}
            payload = broadcast_and_return(next_data)
            {:reply, %{ok: true, state: payload}, next_data}
        end
    end
  end

  def handle_call({:ai_move, strategy, depth, expected_ply}, _from, %{state: state} = data) do
    cond do
      state.is_game_over ->
        {:reply, %{ok: false, error: "Game is already over", state: serialize_data(data)}, data}

      expected_ply != nil and state.ply != expected_ply ->
        {:reply,
         %{
           ok: false,
           stale: true,
           error: "Turn already advanced",
           state: serialize_data(data)
         }, data}

      true ->
        sr = AI.search_best_move(state, strategy, depth)

        case sr.best_move do
          nil ->
            {:reply, %{ok: false, error: "No legal moves", state: serialize_data(data)}, data}

          mv ->
            next_state = MoveGen.make_move_and_advance(state, mv, true)

            telemetry = %{
              strategy: Atom.to_string(strategy),
              depth: depth,
              nodes: sr.nodes,
              time_ms: sr.time_ms,
              score: sr.score,
              phase: sr.phase
            }

            next_data = %{
              data
              | state: next_state,
                telemetry: telemetry,
                version: data.version + 1
            }

            payload = broadcast_and_return(next_data)
            {:reply, %{ok: true, state: payload}, next_data}
        end
    end
  end

  @impl true
  def handle_cast({:unsubscribe, pid}, data) do
    case Map.pop(data.subscribers, pid) do
      {nil, _subs} ->
        {:noreply, data}

      {ref, rest} ->
        Process.demonitor(ref, [:flush])
        {:noreply, %{data | subscribers: rest}}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, data) do
    {:noreply, %{data | subscribers: Map.delete(data.subscribers, pid)}}
  end

  defp sanitize_name(name, player) when is_binary(name) do
    trimmed = name |> String.trim() |> String.slice(0, 24)
    if trimmed == "", do: "#{Board.player_name(player)} Player", else: trimmed
  end

  defp sanitize_name(_name, player), do: "#{Board.player_name(player)} Player"

  defp broadcast_and_return(data) do
    payload = serialize_data(data)

    if map_size(data.subscribers) > 0 do
      encoded = JSON.encode!(payload)

      Enum.each(Map.keys(data.subscribers), fn pid ->
        send(pid, {:three_chess_event, encoded})
      end)
    end

    payload
  end

  defp serialize_data(%{
         state: state,
         telemetry: telemetry,
         version: version,
         seats: seats,
         lan_urls: lan_urls,
         subscribers: subscribers
       }) do
    board_cells =
      for cell <- 0..95 do
        case Board.piece_at(state, cell) do
          {owner, ptype} -> %{owner: owner, type: ptype}
          nil -> nil
        end
      end

    legal =
      if state.is_game_over do
        []
      else
        MoveGen.generate_legal_moves(state, state.side_to_move)
        |> Enum.map(fn {from, to, promo, castle} ->
          %{from: from, to: to, promo: promo, castle: castle}
        end)
      end

    {e0, e1, e2} = AI.evaluate_tuple(state)

    seats_list =
      for p <- 0..2 do
        s = Map.fetch!(seats, p)
        %{player: p, controller: s.controller, client_id: s.client_id, name: s.name}
      end

    %{
      version: version,
      connected_clients: map_size(subscribers),
      lan_urls: lan_urls,
      seats: seats_list,
      board: board_cells,
      side_to_move: state.side_to_move,
      alive_mask: state.alive_mask,
      alive_count: Board.alive_count(state),
      ply: state.ply,
      is_game_over: state.is_game_over,
      winner: state.winner,
      in_check: [
        MoveGen.in_check?(state, 0),
        MoveGen.in_check?(state, 1),
        MoveGen.in_check?(state, 2)
      ],
      last_eliminated_player: state.last_eliminated_player,
      last_eliminated_piece_count: state.last_eliminated_piece_count,
      legal_moves: legal,
      occ_hex: [
        Board.bitboard_hex(elem(state.player_occ, 0)),
        Board.bitboard_hex(elem(state.player_occ, 1)),
        Board.bitboard_hex(elem(state.player_occ, 2))
      ],
      piece_counts: [
        Topology.popcount(elem(state.player_occ, 0)),
        Topology.popcount(elem(state.player_occ, 1)),
        Topology.popcount(elem(state.player_occ, 2))
      ],
      eval_scores: [e0, e1, e2],
      move_history: Enum.take(state.move_history, 50),
      elimination_log: state.elimination_log,
      ai_telemetry: telemetry
    }
  end
end
