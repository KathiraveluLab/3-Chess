defmodule ThreeChess.Benchmark do
  @moduledoc """
  Benchmark harness verifying 96-cell Perft move counts, Option B sudden
  army disappearance state transitions, and MaxN vs. Paranoid search performance.
  """

  alias ThreeChess.{AI, Board, MoveGen, Topology}

  @spec run() :: :ok
  def run do
    IO.puts("3-Chess 96-Bit Bitboard Engine Benchmark (Elixir/OTP)")
    IO.puts("=====================================================")

    initial = Board.new()

    Enum.each(1..3, fn depth ->
      t0 = System.monotonic_time(:microsecond)
      nodes = MoveGen.perft(initial, depth)
      elapsed_ms = (System.monotonic_time(:microsecond) - t0) / 1000.0
      IO.puts("Perft depth #{depth}: #{nodes} nodes (#{Float.round(elapsed_ms, 2)} ms)")
    end)

    demo = Board.elimination_demo()
    pre_count = Topology.popcount(demo.all_occ)
    res = AI.search_best_move(demo, :paranoid, 2)
    after_demo = MoveGen.make_move_and_advance(demo, res.best_move, true)
    post_count = Topology.popcount(after_demo.all_occ)

    IO.puts(
      "Sudden Disappearance Verification: eliminated=#{Board.player_name(after_demo.last_eliminated_player)}, " <>
        "pieces_before=#{pre_count}, pieces_after=#{post_count}, " <>
        "removed=#{after_demo.last_eliminated_piece_count}, alive=#{Board.alive_count(after_demo)}"
    )

    Enum.each([:maxn, :paranoid], fn strat ->
      t0 = System.monotonic_time(:microsecond)

      {final_state, total_nodes, plies} =
        Enum.reduce_while(1..24, {initial, 0, 0}, fn _ply, {st, n_acc, p_acc} ->
          if st.is_game_over do
            {:halt, {st, n_acc, p_acc}}
          else
            sr = AI.search_best_move(st, strat, 2)

            if sr.best_move do
              nxt = MoveGen.make_move_and_advance(st, sr.best_move, true)
              {:cont, {nxt, n_acc + sr.nodes, p_acc + 1}}
            else
              {:halt, {st, n_acc, p_acc}}
            end
          end
        end)

      elapsed_ms = max((System.monotonic_time(:microsecond) - t0) / 1000.0, 0.01)
      nps = round(total_nodes * 1000.0 / elapsed_ms)

      IO.puts(
        "Strategy #{strat}: #{plies} plies, #{total_nodes} nodes in #{Float.round(elapsed_ms, 2)} ms " <>
          "(#{nps} nps), alive=#{Board.alive_count(final_state)}"
      )
    end)

    :ok
  end
end
