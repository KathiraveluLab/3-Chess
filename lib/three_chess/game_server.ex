defmodule ThreeChess.GameServer do
  @moduledoc """
  OTP GenServer holding the active 3-Chess match state and telemetry.
  """

  use GenServer
  alias ThreeChess.{AI, Board, MoveGen, Topology}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  def get_payload, do: GenServer.call(__MODULE__, :get_payload)
  def reset, do: GenServer.call(__MODULE__, :reset)
  def load_demo, do: GenServer.call(__MODULE__, :load_demo)
  def make_move(from, to, promo \\ 0), do: GenServer.call(__MODULE__, {:make_move, from, to, promo})
  def ai_move(strategy \\ :paranoid, depth \\ 2), do: GenServer.call(__MODULE__, {:ai_move, strategy, depth}, 30_000)

  @impl true
  def init(:ok) do
    {:ok, %{state: Board.new(), telemetry: nil}}
  end

  @impl true
  def handle_call(:get_payload, _from, data) do
    {:reply, serialize_state(data.state, data.telemetry), data}
  end

  def handle_call(:reset, _from, _data) do
    next_data = %{state: Board.new(), telemetry: nil}
    {:reply, serialize_state(next_data.state, nil), next_data}
  end

  def handle_call(:load_demo, _from, _data) do
    next_data = %{state: Board.elimination_demo(), telemetry: nil}
    {:reply, serialize_state(next_data.state, nil), next_data}
  end

  def handle_call({:make_move, from, to, promo}, _from, %{state: state} = data) do
    if state.is_game_over do
      {:reply, %{ok: false, error: "Game is already over", state: serialize_state(state, data.telemetry)}, data}
    else
      legal = MoveGen.generate_legal_moves(state, state.side_to_move)

      matching =
        Enum.find(legal, fn {mf, mt, mpromo, _mc} ->
          mf == from and mt == to and (mpromo == 0 or promo == 0 or mpromo == promo)
        end)

      case matching do
        nil ->
          {:reply, %{ok: false, error: "Illegal move", state: serialize_state(state, data.telemetry)}, data}

        {mf, mt, mpromo, mc} ->
          chosen = if mpromo != 0 and promo == 0, do: {mf, mt, 4, mc}, else: {mf, mt, mpromo, mc}
          next_state = MoveGen.make_move_and_advance(state, chosen, true)
          next_data = %{state: next_state, telemetry: data.telemetry}
          {:reply, %{ok: true, state: serialize_state(next_state, data.telemetry)}, next_data}
      end
    end
  end

  def handle_call({:ai_move, strategy, depth}, _from, %{state: state} = data) do
    if state.is_game_over do
      {:reply, %{ok: false, error: "Game is already over", state: serialize_state(state, data.telemetry)}, data}
    else
      sr = AI.search_best_move(state, strategy, depth)

      case sr.best_move do
        nil ->
          {:reply, %{ok: false, error: "No legal moves", state: serialize_state(state, data.telemetry)}, data}

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

          next_data = %{state: next_state, telemetry: telemetry}
          {:reply, %{ok: true, state: serialize_state(next_state, telemetry)}, next_data}
      end
    end
  end

  defp serialize_state(state, telemetry) do
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

    %{
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
