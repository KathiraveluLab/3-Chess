defmodule ThreeChess.MoveGen do
  @moduledoc """
  Legal move generation, check detection, and Option B sudden-disappearance turn
  advancement on the 96-cell three-sector bitboard.
  """

  import Bitwise
  alias ThreeChess.{Board, Topology}

  @type move :: {0..95, 0..95, 0..4, boolean()}

  @doc "Returns the 96-bit capture mask for a pawn owned by `owner` on square `sq`."
  @spec pawn_capture_mask(Board.player_id(), 0..95) :: non_neg_integer()
  def pawn_capture_mask(owner, sq) do
    {s, r, f} = Topology.from_cell(sq)

    if s == owner do
      Topology.diag_rays(sq)
      |> Enum.reduce(0, fn {dr, ray}, acc ->
        if dr == 1 and tuple_size(ray) > 0, do: acc ||| (1 <<< elem(ray, 0)), else: acc
      end)
    else
      if r > 0 do
        nr = r - 1
        m1 = if f > 0, do: 1 <<< Topology.to_cell(s, nr, f - 1), else: 0
        m2 = if f < 7, do: 1 <<< Topology.to_cell(s, nr, f + 1), else: 0
        m1 ||| m2
      else
        0
      end
    end
  end

  @doc "Returns true if `sq` is attacked by any piece belonging to surviving player `attacker`."
  @spec square_attacked_by?(Board.t(), 0..95, Board.player_id()) :: boolean()
  def square_attacked_by?(%Board{} = state, sq, attacker) do
    if not Board.alive?(state, attacker) do
      false
    else
      att = elem(state.pieces, attacker)
      sq_bit = 1 <<< sq

      cond do
        (Topology.king_attacks(sq) &&& elem(att, 5)) != 0 ->
          true

        (Topology.knight_attacks(sq) &&& elem(att, 1)) != 0 ->
          true

        ortho_ray_hits?(state.all_occ, sq, elem(att, 3) ||| elem(att, 4)) ->
          true

        diag_ray_hits?(state.all_occ, sq, elem(att, 2) ||| elem(att, 4)) ->
          true

        pawn_attacks_square?(elem(att, 0), attacker, sq_bit) ->
          true

        true ->
          false
      end
    end
  end

  defp ortho_ray_hits?(_all_occ, _sq, 0), do: false

  defp ortho_ray_hits?(all_occ, sq, rq_mask) do
    rays = Topology.ortho_rays(sq)

    Enum.any?(0..3, fn d ->
      ray_hits_target?(all_occ, rq_mask, elem(rays, d), 0, tuple_size(elem(rays, d)))
    end)
  end

  defp diag_ray_hits?(_all_occ, _sq, 0), do: false

  defp diag_ray_hits?(all_occ, sq, bq_mask) do
    Enum.any?(Topology.diag_rays(sq), fn {_dr, ray} ->
      ray_hits_target?(all_occ, bq_mask, ray, 0, tuple_size(ray))
    end)
  end

  defp ray_hits_target?(_all_occ, _target_mask, _ray, idx, len) when idx >= len, do: false

  defp ray_hits_target?(all_occ, target_mask, ray, idx, len) do
    cell = elem(ray, idx)
    cbit = 1 <<< cell

    if (all_occ &&& cbit) != 0 do
      (target_mask &&& cbit) != 0
    else
      ray_hits_target?(all_occ, target_mask, ray, idx + 1, len)
    end
  end

  defp pawn_attacks_square?(0, _attacker, _sq_bit), do: false

  defp pawn_attacks_square?(pawns_bb, attacker, sq_bit) do
    psq = Topology.lsb_index(pawns_bb)

    if (pawn_capture_mask(attacker, psq) &&& sq_bit) != 0 do
      true
    else
      pawn_attacks_square?(pawns_bb &&& (pawns_bb - 1), attacker, sq_bit)
    end
  end

  @spec attacked_by_any_opponent?(Board.t(), 0..95, Board.player_id()) :: boolean()
  def attacked_by_any_opponent?(state, sq, player) do
    Enum.any?(0..2, fn opp ->
      opp != player and square_attacked_by?(state, sq, opp)
    end)
  end

  @doc "Returns true if `player`'s King is currently under check from any surviving opponent."
  @spec in_check?(Board.t(), Board.player_id()) :: boolean()
  def in_check?(%Board{} = state, player) do
    if not Board.alive?(state, player) do
      false
    else
      king_bb = elem(elem(state.pieces, player), 5)

      if king_bb == 0 do
        false
      else
        king_sq = Topology.lsb_index(king_bb)
        attacked_by_any_opponent?(state, king_sq, player)
      end
    end
  end

  @doc "Applies a move directly without checking legality or advancing turns."
  @spec apply_raw_move(Board.t(), Board.player_id(), move()) :: Board.t()
  def apply_raw_move(%Board{} = state, player, {from, to, promo, is_castle}) do
    {^player, ptype} = Board.piece_at(state, from)

    state =
      case Board.piece_at(state, to) do
        {victim_p, victim_t} ->
          s1 = Board.remove_piece(state, victim_p, victim_t, to)
          {_vs, vr, vf} = Topology.from_cell(to)

          if vr == 0 do
            c =
              cond do
                vf == 7 -> s1.castling &&& bnot(1 <<< (victim_p * 2))
                vf == 0 -> s1.castling &&& bnot(2 <<< (victim_p * 2))
                true -> s1.castling
              end

            %{s1 | castling: c}
          else
            s1
          end

        nil ->
          state
      end

    final_type = if promo != 0, do: promo, else: ptype

    state =
      state
      |> Board.remove_piece(player, ptype, from)
      |> Board.place_piece(player, final_type, to)

    state =
      if is_castle do
        {_ts, _tr, tf} = Topology.from_cell(to)

        cond do
          tf == 6 ->
            state
            |> Board.remove_piece(player, 3, Topology.to_cell(player, 0, 7))
            |> Board.place_piece(player, 3, Topology.to_cell(player, 0, 5))

          tf == 2 ->
            state
            |> Board.remove_piece(player, 3, Topology.to_cell(player, 0, 0))
            |> Board.place_piece(player, 3, Topology.to_cell(player, 0, 3))

          true ->
            state
        end
      else
        state
      end

    new_castling =
      cond do
        ptype == 5 ->
          state.castling &&& bnot(0b11 <<< (player * 2))

        ptype == 3 ->
          {fs, fr, ff} = Topology.from_cell(from)

          if fs == player and fr == 0 do
            cond do
              ff == 7 -> state.castling &&& bnot(1 <<< (player * 2))
              ff == 0 -> state.castling &&& bnot(2 <<< (player * 2))
              true -> state.castling
            end
          else
            state.castling
          end

        true ->
          state.castling
      end

    %{state | castling: new_castling}
  end

  @doc "Generates all pseudo-legal moves for `player`."
  @spec generate_pseudo_moves(Board.t(), Board.player_id()) :: [move()]
  def generate_pseudo_moves(%Board{} = state, player) do
    if not Board.alive?(state, player) do
      []
    else
      own_occ = elem(state.player_occ, player)
      enemy_occ = state.all_occ &&& bnot(own_occ)
      p_tuple = elem(state.pieces, player)

      acc = []
      acc = gen_pawns(state, player, elem(p_tuple, 0), enemy_occ, acc)
      acc = gen_leapers(elem(p_tuple, 1), own_occ, &Topology.knight_attacks/1, acc)
      acc = gen_diag_sliders(state.all_occ, own_occ, elem(p_tuple, 2), acc)
      acc = gen_ortho_sliders(state.all_occ, own_occ, elem(p_tuple, 3), acc)
      acc = gen_ortho_sliders(state.all_occ, own_occ, elem(p_tuple, 4), acc)
      acc = gen_diag_sliders(state.all_occ, own_occ, elem(p_tuple, 4), acc)
      gen_kings(state, player, elem(p_tuple, 5), own_occ, acc)
    end
  end

  defp gen_pawns(_state, _player, 0, _enemy_occ, acc), do: acc

  defp gen_pawns(state, player, pawns_bb, enemy_occ, acc) do
    from = Topology.lsb_index(pawns_bb)
    {s, r, f} = Topology.from_cell(from)

    acc =
      if s == player do
        fwd_ray = elem(Topology.ortho_rays(from), 0)

        if tuple_size(fwd_ray) > 0 do
          push1 = elem(fwd_ray, 0)

          if (state.all_occ &&& (1 <<< push1)) == 0 do
            a1 = [{from, push1, 0, false} | acc]

            if r == 1 and tuple_size(fwd_ray) > 1 do
              push2 = elem(fwd_ray, 1)

              if (state.all_occ &&& (1 <<< push2)) == 0 do
                [{from, push2, 0, false} | a1]
              else
                a1
              end
            else
              a1
            end
          else
            acc
          end
        else
          acc
        end
      else
        if r > 0 do
          push1 = Topology.to_cell(s, r - 1, f)

          if (state.all_occ &&& (1 <<< push1)) == 0 do
            if r - 1 == 0, do: add_promotions(from, push1, acc), else: [{from, push1, 0, false} | acc]
          else
            acc
          end
        else
          acc
        end
      end

    caps = pawn_capture_mask(player, from) &&& enemy_occ
    acc = emit_pawn_captures(caps, from, s, player, acc)
    gen_pawns(state, player, pawns_bb &&& (pawns_bb - 1), enemy_occ, acc)
  end

  defp emit_pawn_captures(0, _from, _src_sector, _player, acc), do: acc

  defp emit_pawn_captures(caps, from, src_sector, player, acc) do
    to = Topology.lsb_index(caps)
    {ts, tr, _tf} = Topology.from_cell(to)

    acc =
      if src_sector != player and ts == src_sector and tr == 0 do
        add_promotions(from, to, acc)
      else
        [{from, to, 0, false} | acc]
      end

    emit_pawn_captures(caps &&& (caps - 1), from, src_sector, player, acc)
  end

  defp add_promotions(from, to, acc) do
    [
      {from, to, 4, false},
      {from, to, 3, false},
      {from, to, 2, false},
      {from, to, 1, false}
      | acc
    ]
  end

  defp gen_leapers(0, _own_occ, _table_fn, acc), do: acc

  defp gen_leapers(bb, own_occ, table_fn, acc) do
    from = Topology.lsb_index(bb)
    targets = table_fn.(from) &&& bnot(own_occ)
    acc = emit_target_bits(targets, from, acc)
    gen_leapers(bb &&& (bb - 1), own_occ, table_fn, acc)
  end

  defp emit_target_bits(0, _from, acc), do: acc

  defp emit_target_bits(targets, from, acc) do
    to = Topology.lsb_index(targets)
    emit_target_bits(targets &&& (targets - 1), from, [{from, to, 0, false} | acc])
  end

  defp gen_ortho_sliders(_all_occ, _own_occ, 0, acc), do: acc

  defp gen_ortho_sliders(all_occ, own_occ, bb, acc) do
    from = Topology.lsb_index(bb)
    rays = Topology.ortho_rays(from)

    acc =
      Enum.reduce(0..3, acc, fn d, a ->
        ray = elem(rays, d)
        walk_ray_moves(all_occ, own_occ, from, ray, 0, tuple_size(ray), a)
      end)

    gen_ortho_sliders(all_occ, own_occ, bb &&& (bb - 1), acc)
  end

  defp walk_ray_moves(_all_occ, _own_occ, _from, _ray, idx, len, acc) when idx >= len, do: acc

  defp walk_ray_moves(all_occ, own_occ, from, ray, idx, len, acc) do
    to = elem(ray, idx)
    tbit = 1 <<< to

    cond do
      (own_occ &&& tbit) != 0 ->
        acc

      (all_occ &&& tbit) != 0 ->
        [{from, to, 0, false} | acc]

      true ->
        walk_ray_moves(all_occ, own_occ, from, ray, idx + 1, len, [{from, to, 0, false} | acc])
    end
  end

  defp gen_diag_sliders(_all_occ, _own_occ, 0, acc), do: acc

  defp gen_diag_sliders(all_occ, own_occ, bb, acc) do
    from = Topology.lsb_index(bb)

    {acc, _seen} =
      Enum.reduce(Topology.diag_rays(from), {acc, 0}, fn {_dr, ray}, {a, seen} ->
        walk_diag_ray(all_occ, own_occ, from, ray, 0, tuple_size(ray), a, seen)
      end)

    gen_diag_sliders(all_occ, own_occ, bb &&& (bb - 1), acc)
  end

  defp walk_diag_ray(_all_occ, _own_occ, _from, _ray, idx, len, acc, seen) when idx >= len do
    {acc, seen}
  end

  defp walk_diag_ray(all_occ, own_occ, from, ray, idx, len, acc, seen) do
    to = elem(ray, idx)
    tbit = 1 <<< to

    cond do
      (own_occ &&& tbit) != 0 ->
        {acc, seen}

      (all_occ &&& tbit) != 0 ->
        if (seen &&& tbit) == 0 do
          {[{from, to, 0, false} | acc], seen ||| tbit}
        else
          {acc, seen}
        end

      true ->
        if (seen &&& tbit) == 0 do
          walk_diag_ray(all_occ, own_occ, from, ray, idx + 1, len, [{from, to, 0, false} | acc], seen ||| tbit)
        else
          walk_diag_ray(all_occ, own_occ, from, ray, idx + 1, len, acc, seen)
        end
    end
  end

  defp gen_kings(_state, _player, 0, _own_occ, acc), do: acc

  defp gen_kings(state, player, king_bb, own_occ, acc) do
    from = Topology.lsb_index(king_bb)
    targets = Topology.king_attacks(from) &&& bnot(own_occ)
    acc = emit_target_bits(targets, from, acc)

    ks_bit = 1 <<< (player * 2)
    qs_bit = 2 <<< (player * 2)
    k_home = Topology.to_cell(player, 0, 4)
    rooks_bb = elem(elem(state.pieces, player), 3)

    if from == k_home and (state.castling &&& (ks_bit ||| qs_bit)) != 0 and
         not attacked_by_any_opponent?(state, k_home, player) do
      acc =
        if (state.castling &&& ks_bit) != 0 do
          f1 = Topology.to_cell(player, 0, 5)
          g1 = Topology.to_cell(player, 0, 6)
          h1 = Topology.to_cell(player, 0, 7)

          if (rooks_bb &&& (1 <<< h1)) != 0 and
               (state.all_occ &&& ((1 <<< f1) ||| (1 <<< g1))) == 0 and
               not attacked_by_any_opponent?(state, f1, player) do
            [{from, g1, 0, true} | acc]
          else
            acc
          end
        else
          acc
        end

      if (state.castling &&& qs_bit) != 0 do
        b1 = Topology.to_cell(player, 0, 1)
        c1 = Topology.to_cell(player, 0, 2)
        d1 = Topology.to_cell(player, 0, 3)
        a1 = Topology.to_cell(player, 0, 0)

        if (rooks_bb &&& (1 <<< a1)) != 0 and
             (state.all_occ &&& ((1 <<< b1) ||| (1 <<< c1) ||| (1 <<< d1))) == 0 and
             not attacked_by_any_opponent?(state, d1, player) do
          [{from, c1, 0, true} | acc]
        else
          acc
        end
      else
        acc
      end
    else
      acc
    end
  end

  @doc "Generates all legal moves for `player`."
  @spec generate_legal_moves(Board.t(), Board.player_id()) :: [move()]
  def generate_legal_moves(%Board{} = state, player) do
    if not Board.alive?(state, player) do
      []
    else
      generate_pseudo_moves(state, player)
      |> Enum.filter(fn mv ->
        next_state = apply_raw_move(state, player, mv)
        not in_check?(next_state, player)
      end)
    end
  end

  defp next_alive_player(state, current) do
    c1 = rem(current + 1, 3)

    if Board.alive?(state, c1) do
      c1
    else
      c2 = rem(current + 2, 3)
      if Board.alive?(state, c2), do: c2, else: current
    end
  end

  defp sole_survivor(state) do
    Enum.find(0..2, fn p -> Board.alive?(state, p) end)
  end

  @doc """
  Formats a move into algebraic notation (e.g. "W:e2 -> W:e4") before applying it.
  """
  @spec format_move(Board.t(), move()) :: String.t()
  def format_move(state, {from, to, promo, is_castle}) do
    if is_castle do
      {_s, _r, tf} = Topology.from_cell(to)
      if tf == 6, do: "O-O", else: "O-O-O"
    else
      piece_prefix =
        case Board.piece_at(state, from) do
          {_p, 0} -> ""
          {_p, pt} -> Board.piece_char(pt)
          nil -> ""
        end

      cap_sym = if Board.piece_at(state, to) != nil, do: "x", else: "-"
      promo_suffix = if promo != 0, do: "=" <> Board.piece_char(promo), else: ""
      "#{piece_prefix}#{Topology.cell_label(from)}#{cap_sym}#{Topology.cell_label(to)}#{promo_suffix}"
    end
  end

  @doc """
  Applies a legal move, records history if `record_history?` is true, and resolves
  checkmate / Option B sudden army disappearance across surviving players.
  """
  @spec make_move_and_advance(Board.t(), move(), boolean()) :: Board.t()
  def make_move_and_advance(%Board{} = state, mv, record_history? \\ false) do
    mover = state.side_to_move

    notation = if record_history?, do: format_move(state, mv), else: nil

    state =
      state
      |> apply_raw_move(mover, mv)
      |> Map.put(:ply, state.ply + 1)
      |> Map.put(:last_eliminated_player, nil)
      |> Map.put(:last_eliminated_piece_count, 0)

    state =
      if record_history? do
        entry = %{
          ply: state.ply,
          player: mover,
          player_name: Board.player_name(mover),
          notation: notation
        }

        %{state | move_history: [entry | state.move_history]}
      else
        state
      end

    cur = next_alive_player(state, mover)
    resolve_turn_loop(state, cur, mover, 0)
  end

  defp resolve_turn_loop(state, _cur, mover, 3), do: %{state | side_to_move: mover}

  defp resolve_turn_loop(state, cur, mover, depth) do
    if Board.alive_count(state) <= 1 do
      w = sole_survivor(state)
      %{state | is_game_over: true, winner: w, side_to_move: w || mover}
    else
      case generate_legal_moves(state, cur) do
        [_ | _] ->
          %{state | side_to_move: cur}

        [] ->
          if in_check?(state, cur) do
            {s_after, _removed} = Board.eliminate_army(state, cur, mover, "checkmate")

            if Board.alive_count(s_after) == 1 do
              w = sole_survivor(s_after)
              %{s_after | is_game_over: true, winner: w, side_to_move: w || mover}
            else
              nxt = next_alive_player(s_after, cur)
              resolve_turn_loop(s_after, nxt, mover, depth + 1)
            end
          else
            if Board.alive_count(state) == 2 do
              %{state | is_game_over: true, winner: nil, side_to_move: cur}
            else
              {s_after, _removed} = Board.eliminate_army(state, cur, mover, "stalemate")
              nxt = next_alive_player(s_after, cur)
              resolve_turn_loop(s_after, nxt, mover, depth + 1)
            end
          end
      end
    end
  end

  @doc "Perft move count verification up to `depth`."
  @spec perft(Board.t(), non_neg_integer()) :: non_neg_integer()
  def perft(_state, 0), do: 1
  def perft(%Board{is_game_over: true}, _depth), do: 1

  def perft(state, depth) do
    moves = generate_legal_moves(state, state.side_to_move)

    if depth == 1 do
      length(moves)
    else
      Enum.reduce(moves, 0, fn mv, acc ->
        child = make_move_and_advance(state, mv, false)
        acc + perft(child, depth - 1)
      end)
    end
  end
end
