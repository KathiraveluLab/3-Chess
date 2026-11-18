defmodule ThreeChess.Board do
  @moduledoc """
  96-bit bitboard representation for 3-Chess (White = 0, Red = 1, Black = 2)
  implementing Option B Sudden Army Disappearance upon checkmate.
  """

  import Bitwise
  alias ThreeChess.Topology

  @empty_player_pieces {0, 0, 0, 0, 0, 0}

  # Piece type indices: 0 = pawn, 1 = knight, 2 = bishop, 3 = rook, 4 = queen, 5 = king
  @piece_names {:pawn, :knight, :bishop, :rook, :queen, :king}
  @piece_chars {"P", "N", "B", "R", "Q", "K"}
  @player_names {"White", "Red", "Black"}

  defstruct pieces: {@empty_player_pieces, @empty_player_pieces, @empty_player_pieces},
            player_occ: {0, 0, 0},
            all_occ: 0,
            alive_mask: 0b111,
            castling: 0b111111,
            side_to_move: 0,
            ply: 0,
            eliminated_order: [],
            last_eliminated_player: nil,
            last_eliminated_piece_count: 0,
            winner: nil,
            is_game_over: false,
            move_history: [],
            elimination_log: []

  @type player_id :: 0 | 1 | 2
  @type piece_type :: 0 | 1 | 2 | 3 | 4 | 5
  @type t :: %__MODULE__{}

  @spec player_name(player_id()) :: String.t()
  def player_name(p), do: elem(@player_names, p)

  @spec piece_name(piece_type()) :: atom()
  def piece_name(t), do: elem(@piece_names, t)

  @spec piece_char(piece_type()) :: String.t()
  def piece_char(t), do: elem(@piece_chars, t)

  @doc "Initializes the standard 48-piece 96-cell starting position."
  @spec new() :: t()
  def new do
    back_rank = [3, 1, 2, 4, 5, 2, 1, 3]

    Enum.reduce(0..2, %__MODULE__{}, fn s, st ->
      Enum.reduce(0..7, st, fn f, acc ->
        ptype = Enum.at(back_rank, f)

        acc
        |> place_piece(s, ptype, Topology.to_cell(s, 0, f))
        |> place_piece(s, 0, Topology.to_cell(s, 1, f))
      end)
    end)
  end

  @doc """
  Initializes a tactical position where White is 1 move away from delivering
  checkmate to Red while Red retains multiple pieces on the board, verifying
  and demonstrating Option B Sudden Army Disappearance.
  """
  @spec elimination_demo() :: t()
  def elimination_demo do
    %__MODULE__{castling: 0}
    # White
    |> place_piece(0, 5, Topology.to_cell(0, 0, 6))
    |> place_piece(0, 4, Topology.to_cell(1, 2, 5))
    |> place_piece(0, 1, Topology.to_cell(1, 3, 5))
    |> place_piece(0, 3, Topology.to_cell(0, 2, 4))
    |> place_piece(0, 0, Topology.to_cell(0, 1, 5))
    |> place_piece(0, 0, Topology.to_cell(0, 1, 6))
    # Red (King trapped on h1 (1, 0, 7); White Qg2# at (1, 1, 6) mates immediately)
    |> place_piece(1, 5, Topology.to_cell(1, 0, 7))
    |> place_piece(1, 0, Topology.to_cell(1, 1, 7))
    |> place_piece(1, 0, Topology.to_cell(1, 0, 6))
    |> place_piece(1, 3, Topology.to_cell(1, 0, 0))
    |> place_piece(1, 2, Topology.to_cell(1, 0, 2))
    |> place_piece(1, 4, Topology.to_cell(1, 2, 0))
    # Black
    |> place_piece(2, 5, Topology.to_cell(2, 0, 4))
    |> place_piece(2, 4, Topology.to_cell(2, 1, 3))
    |> place_piece(2, 3, Topology.to_cell(2, 0, 0))
    |> place_piece(2, 1, Topology.to_cell(2, 2, 5))
    |> place_piece(2, 0, Topology.to_cell(2, 1, 4))
    |> place_piece(2, 0, Topology.to_cell(2, 1, 5))
  end

  @spec place_piece(t(), player_id(), piece_type(), 0..95) :: t()
  def place_piece(%__MODULE__{} = state, player, ptype, cell) do
    bit = 1 <<< cell
    p_tuple = elem(state.pieces, player)
    updated_bb = elem(p_tuple, ptype) ||| bit
    updated_p_tuple = put_elem(p_tuple, ptype, updated_bb)
    updated_pieces = put_elem(state.pieces, player, updated_p_tuple)

    updated_pocc = elem(state.player_occ, player) ||| bit
    updated_occ_tuple = put_elem(state.player_occ, player, updated_pocc)

    %{
      state
      | pieces: updated_pieces,
        player_occ: updated_occ_tuple,
        all_occ: state.all_occ ||| bit
    }
  end

  @spec remove_piece(t(), player_id(), piece_type(), 0..95) :: t()
  def remove_piece(%__MODULE__{} = state, player, ptype, cell) do
    inv = bnot(1 <<< cell) &&& Topology.mask96()
    p_tuple = elem(state.pieces, player)
    updated_bb = elem(p_tuple, ptype) &&& inv
    updated_p_tuple = put_elem(p_tuple, ptype, updated_bb)
    updated_pieces = put_elem(state.pieces, player, updated_p_tuple)

    updated_pocc = elem(state.player_occ, player) &&& inv
    updated_occ_tuple = put_elem(state.player_occ, player, updated_pocc)

    %{
      state
      | pieces: updated_pieces,
        player_occ: updated_occ_tuple,
        all_occ: state.all_occ &&& inv
    }
  end

  @spec piece_at(t(), 0..95) :: {player_id(), piece_type()} | nil
  def piece_at(%__MODULE__{all_occ: all_occ} = state, cell) do
    bit = 1 <<< cell

    if (all_occ &&& bit) == 0 do
      nil
    else
      find_owner_piece(state, bit, 0)
    end
  end

  defp find_owner_piece(_state, _bit, 3), do: nil

  defp find_owner_piece(state, bit, p) do
    if (elem(state.player_occ, p) &&& bit) != 0 do
      p_tuple = elem(state.pieces, p)
      ptype = find_ptype(p_tuple, bit, 0)
      if ptype != nil, do: {p, ptype}, else: find_owner_piece(state, bit, p + 1)
    else
      find_owner_piece(state, bit, p + 1)
    end
  end

  defp find_ptype(_p_tuple, _bit, 6), do: nil

  defp find_ptype(p_tuple, bit, t) do
    if (elem(p_tuple, t) &&& bit) != 0, do: t, else: find_ptype(p_tuple, bit, t + 1)
  end

  @spec alive?(t(), player_id()) :: boolean()
  def alive?(%__MODULE__{alive_mask: mask}, player) do
    (mask &&& (1 <<< player)) != 0
  end

  @spec alive_count(t()) :: non_neg_integer()
  def alive_count(%__MODULE__{alive_mask: mask}) do
    Topology.popcount(mask)
  end

  @doc """
  Option B Sudden Army Disappearance: clears all 6 piece bitboards and the
  occupancy mask for `player` in O(1), updates `alive_mask`, and logs the removal.
  """
  @spec eliminate_army(t(), player_id(), player_id(), String.t()) :: {t(), non_neg_integer()}
  def eliminate_army(%__MODULE__{} = state, player, by_player, reason) do
    removed = Topology.popcount(elem(state.player_occ, player))
    updated_pieces = put_elem(state.pieces, player, @empty_player_pieces)
    updated_occ_tuple = put_elem(state.player_occ, player, 0)

    new_all =
      elem(updated_occ_tuple, 0) |||
        elem(updated_occ_tuple, 1) |||
        elem(updated_occ_tuple, 2)

    new_alive = state.alive_mask &&& bnot(1 <<< player)
    new_castling = state.castling &&& bnot(0b11 <<< (player * 2))

    event = %{
      ply: state.ply,
      eliminated: player,
      eliminated_name: player_name(player),
      by: by_player,
      by_name: player_name(by_player),
      reason: reason,
      pieces_removed: removed,
      surviving_count: Topology.popcount(new_alive)
    }

    updated = %{
      state
      | pieces: updated_pieces,
        player_occ: updated_occ_tuple,
        all_occ: new_all,
        alive_mask: new_alive,
        castling: new_castling,
        eliminated_order: state.eliminated_order ++ [player],
        last_eliminated_player: player,
        last_eliminated_piece_count: removed,
        elimination_log: [event | state.elimination_log]
    }

    {updated, removed}
  end

  @doc "Formats a 96-bit integer as three 32-bit hex segments matching sector words [2:1:0]."
  @spec bitboard_hex(non_neg_integer()) :: String.t()
  def bitboard_hex(bb) do
    w2 = (bb >>> 64) &&& 0xFFFFFFFF
    w1 = (bb >>> 32) &&& 0xFFFFFFFF
    w0 = bb &&& 0xFFFFFFFF

    "0x" <>
      pad8(Integer.to_string(w2, 16)) <>
      "_" <>
      pad8(Integer.to_string(w1, 16)) <>
      "_" <>
      pad8(Integer.to_string(w0, 16))
  end

  defp pad8(str) when byte_size(str) >= 8, do: str
  defp pad8(str), do: String.duplicate("0", 8 - byte_size(str)) <> str
end
