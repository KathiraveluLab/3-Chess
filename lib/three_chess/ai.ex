defmodule ThreeChess.AI do
  @moduledoc """
  Multi-player search engine supporting 3-player MaxN and Paranoid search with
  automatic phase transition to 2-player Negamax Alpha-Beta after the first
  player elimination.
  """

  import Bitwise
  alias ThreeChess.{Board, MoveGen, Topology}

  @piece_values {100, 320, 330, 500, 900, 0}

  @center_rosette_mask (for s <- 0..2, r <- 2..3, f <- 2..5, reduce: 0 do
                          acc -> acc ||| (1 <<< Topology.to_cell(s, r, f))
                        end)

  @doc "Evaluates the position for all three players as a 3-tuple {v0, v1, v2} of relative utilities."
  @spec evaluate_tuple(Board.t()) :: {integer(), integer(), integer()}
  def evaluate_tuple(%Board{} = state) do
    raw =
      for p <- 0..2 do
        if not Board.alive?(state, p) do
          0
        else
          p_tuple = elem(state.pieces, p)

          mat_pos =
            Enum.reduce(0..4, 10_000, fn t, acc ->
              val = elem(@piece_values, t)
              sum_piece_score(elem(p_tuple, t), p, t, val, acc)
            end)

          if MoveGen.in_check?(state, p), do: mat_pos - 45, else: mat_pos
        end
      end

    r0 = Enum.at(raw, 0)
    r1 = Enum.at(raw, 1)
    r2 = Enum.at(raw, 2)
    raw_t = {r0, r1, r2}

    rel =
      for p <- 0..2 do
        if not Board.alive?(state, p) do
          -20_000
        else
          opp_sum =
            Enum.reduce(0..2, 0, fn o, s_acc ->
              if o != p, do: s_acc + elem(raw_t, o), else: s_acc
            end)

          elem(raw_t, p) - div(opp_sum, 2)
        end
      end

    {Enum.at(rel, 0), Enum.at(rel, 1), Enum.at(rel, 2)}
  end

  defp sum_piece_score(0, _owner, _ptype, _val, acc), do: acc

  defp sum_piece_score(bb, owner, ptype, val, acc) do
    sq = Topology.lsb_index(bb)
    bonus = if (@center_rosette_mask &&& (1 <<< sq)) != 0, do: 18, else: 0

    adv =
      if ptype == 0 do
        {s, r, _f} = Topology.from_cell(sq)
        if s == owner, do: r * 8, else: (4 - r) * 22
      else
        0
      end

    sum_piece_score(bb &&& (bb - 1), owner, ptype, val, acc + val + bonus + adv)
  end

  defp order_moves(state, moves) do
    Enum.sort_by(
      moves,
      fn {_from, to, promo, _castle} ->
        cap_score =
          case Board.piece_at(state, to) do
            {_p, vt} -> 10 * elem(@piece_values, vt) + 100
            nil -> 0
          end

        promo_score = if promo != 0, do: elem(@piece_values, promo) + 200, else: 0
        center_score = if (@center_rosette_mask &&& (1 <<< to)) != 0, do: 25, else: 0
        -(cap_score + promo_score + center_score)
      end
    )
  end

  @doc """
  Searches for the best move using `:maxn` or `:paranoid` in the 3-player phase,
  automatically transitioning to 2-player Negamax Alpha-Beta when 2 players remain.
  """
  @spec search_best_move(Board.t(), :maxn | :paranoid, pos_integer()) :: map()
  def search_best_move(%Board{is_game_over: true}, _strategy, _depth) do
    %{best_move: nil, score: 0, nodes: 0, time_ms: 0, phase: "game_over"}
  end

  def search_best_move(%Board{} = state, strategy, depth) do
    start_us = System.monotonic_time(:microsecond)
    root_player = state.side_to_move
    moves = MoveGen.generate_legal_moves(state, root_player) |> order_moves_for(state)
    alive_cnt = Board.alive_count(state)

    result =
      cond do
        moves == [] ->
          %{best_move: nil, score: 0, nodes: 1, phase: phase_label(alive_cnt, strategy)}

        alive_cnt == 2 ->
          {best_mv, best_sc, nodes} =
            Enum.reduce(moves, {hd(moves), -1_000_000, 0}, fn mv, {b_mv, alpha, n_acc} ->
              child = MoveGen.make_move_and_advance(state, mv, false)
              {sc, sub_nodes} = alpha_beta_2p(child, max(depth - 1, 0), -1_000_000, -alpha)
              neg_sc = -sc

              if neg_sc > alpha do
                {mv, neg_sc, n_acc + sub_nodes}
              else
                {b_mv, alpha, n_acc + sub_nodes}
              end
            end)

          %{best_move: best_mv, score: best_sc, nodes: nodes, phase: "2-Player Alpha-Beta"}

        strategy == :maxn ->
          search_moves = Enum.take(moves, 24)

          {best_mv, best_sc, nodes} =
            Enum.reduce(search_moves, {hd(search_moves), -1_000_000, 0}, fn mv,
                                                                              {b_mv, b_sc, n_acc} ->
              child = MoveGen.make_move_and_advance(state, mv, false)
              {tuple, sub_nodes} = maxn_search(child, max(depth - 1, 0))
              sc = elem(tuple, root_player)

              if sc > b_sc do
                {mv, sc, n_acc + sub_nodes}
              else
                {b_mv, b_sc, n_acc + sub_nodes}
              end
            end)

          %{best_move: best_mv, score: best_sc, nodes: nodes, phase: "3-Player MaxN"}

        true ->
          {best_mv, best_sc, nodes} =
            Enum.reduce(moves, {hd(moves), -1_000_000, 0}, fn mv, {b_mv, alpha, n_acc} ->
              child = MoveGen.make_move_and_advance(state, mv, false)
              {sc, sub_nodes} = paranoid_search(child, root_player, max(depth - 1, 0), alpha, 1_000_000)

              if sc > alpha do
                {mv, sc, n_acc + sub_nodes}
              else
                {b_mv, alpha, n_acc + sub_nodes}
              end
            end)

          %{best_move: best_mv, score: best_sc, nodes: nodes, phase: "3-Player Paranoid"}
      end

    elapsed_ms = max(Float.round((System.monotonic_time(:microsecond) - start_us) / 1000.0, 2), 0.01)
    Map.put(result, :time_ms, elapsed_ms)
  end

  defp order_moves_for(moves, state), do: order_moves(state, moves)

  defp phase_label(2, _), do: "2-Player Alpha-Beta"
  defp phase_label(_, :maxn), do: "3-Player MaxN"
  defp phase_label(_, :paranoid), do: "3-Player Paranoid"

  defp alpha_beta_2p(%Board{is_game_over: true, winner: winner, side_to_move: stm}, depth, _a, _b) do
    score =
      case winner do
        nil -> 0
        ^stm -> 50_000 + depth * 10
        _ -> -50_000 - depth * 10
      end

    {score, 1}
  end

  defp alpha_beta_2p(state, 0, _alpha, _beta) do
    {elem(evaluate_tuple(state), state.side_to_move), 1}
  end

  defp alpha_beta_2p(state, depth, alpha, beta) do
    stm = state.side_to_move
    moves = MoveGen.generate_legal_moves(state, stm) |> order_moves_for(state)

    if moves == [] do
      {elem(evaluate_tuple(state), stm), 1}
    else
      ab_loop(moves, state, depth, alpha, beta, -1_000_000, 1)
    end
  end

  defp ab_loop([], _state, _depth, _alpha, _beta, best, nodes), do: {best, nodes}

  defp ab_loop([mv | rest], state, depth, alpha, beta, best, nodes) do
    child = MoveGen.make_move_and_advance(state, mv, false)
    {child_sc, sub_nodes} = alpha_beta_2p(child, depth - 1, -beta, -alpha)
    sc = -child_sc
    new_best = max(best, sc)
    new_alpha = max(alpha, sc)
    new_nodes = nodes + sub_nodes

    if new_alpha >= beta do
      {new_best, new_nodes}
    else
      ab_loop(rest, state, depth, new_alpha, beta, new_best, new_nodes)
    end
  end

  defp maxn_search(%Board{is_game_over: true} = state, _depth), do: {evaluate_tuple(state), 1}
  defp maxn_search(state, 0), do: {evaluate_tuple(state), 1}

  defp maxn_search(state, depth) do
    stm = state.side_to_move
    moves = MoveGen.generate_legal_moves(state, stm) |> order_moves_for(state) |> Enum.take(18)

    case moves do
      [] ->
        {evaluate_tuple(state), 1}

      [first_mv | rest] ->
        c0 = MoveGen.make_move_and_advance(state, first_mv, false)
        {t0, n0} = maxn_search(c0, depth - 1)

        Enum.reduce(rest, {t0, 1 + n0}, fn mv, {best_t, n_acc} ->
          child = MoveGen.make_move_and_advance(state, mv, false)
          {t, sub_n} = maxn_search(child, depth - 1)

          if elem(t, stm) > elem(best_t, stm) do
            {t, n_acc + sub_n}
          else
            {best_t, n_acc + sub_n}
          end
        end)
    end
  end

  defp paranoid_search(%Board{is_game_over: true} = state, root, _depth, _a, _b) do
    {elem(evaluate_tuple(state), root), 1}
  end

  defp paranoid_search(state, root, 0, _alpha, _beta) do
    {elem(evaluate_tuple(state), root), 1}
  end

  defp paranoid_search(state, root, depth, alpha, beta) do
    if not Board.alive?(state, root) do
      {elem(evaluate_tuple(state), root), 1}
    else
      stm = state.side_to_move
      moves = MoveGen.generate_legal_moves(state, stm) |> order_moves_for(state)

      if moves == [] do
        {elem(evaluate_tuple(state), root), 1}
      else
        if stm == root do
          paranoid_max(moves, state, root, depth, alpha, beta, -1_000_000, 1)
        else
          paranoid_min(moves, state, root, depth, alpha, beta, 1_000_000, 1)
        end
      end
    end
  end

  defp paranoid_max([], _state, _root, _depth, _alpha, _beta, best, nodes), do: {best, nodes}

  defp paranoid_max([mv | rest], state, root, depth, alpha, beta, best, nodes) do
    child = MoveGen.make_move_and_advance(state, mv, false)
    {sc, sub_n} = paranoid_search(child, root, depth - 1, alpha, beta)
    new_best = max(best, sc)
    new_alpha = max(alpha, sc)
    new_nodes = nodes + sub_n

    if new_alpha >= beta do
      {new_best, new_nodes}
    else
      paranoid_max(rest, state, root, depth, new_alpha, beta, new_best, new_nodes)
    end
  end

  defp paranoid_min([], _state, _root, _depth, _alpha, _beta, best, nodes), do: {best, nodes}

  defp paranoid_min([mv | rest], state, root, depth, alpha, beta, best, nodes) do
    child = MoveGen.make_move_and_advance(state, mv, false)
    {sc, sub_n} = paranoid_search(child, root, depth - 1, alpha, beta)
    new_best = min(best, sc)
    new_beta = min(beta, sc)
    new_nodes = nodes + sub_n

    if alpha >= new_beta do
      {new_best, new_nodes}
    else
      paranoid_min(rest, state, root, depth, alpha, new_beta, new_best, new_nodes)
    end
  end
end
