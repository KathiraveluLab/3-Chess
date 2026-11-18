defmodule ThreeChess.Topology do
  @moduledoc """
  Compile-time topology and 96-bit bitboard lookup tables for the 96-cell
  three-sector hexagonal-perimeter 3-Chess board.

  Sectors are ordered clockwise: 0 = White, 1 = Red, 2 = Black.
  Each sector contains 4 ranks (0 = back rank, 3 = central frontier)
  and 8 files (0..7 left-to-right from that player's perspective).
  """

  import Bitwise
  alias ThreeChess.Topology.Builder

  @mask96 (1 <<< 96) - 1

  @ctz8 List.to_tuple(
          for i <- 0..255 do
            if i == 0 do
              8
            else
              Enum.find(0..7, fn b -> (i &&& 1 <<< b) != 0 end)
            end
          end
        )

  @ortho_rays Builder.build_ortho_rays()
  @diag_rays Builder.build_diag_rays()
  @knight_attacks Builder.build_knight_attacks()
  @king_attacks Builder.build_king_attacks(@ortho_rays, @diag_rays)

  @doc "Converts {sector, rank, file} to linear cell index 0..95."
  @spec to_cell(0..2, 0..3, 0..7) :: 0..95
  def to_cell(sector, rank, file), do: sector * 32 + rank * 8 + file

  @doc "Converts linear cell index 0..95 to {sector, rank, file}."
  @spec from_cell(0..95) :: {0..2, 0..3, 0..7}
  def from_cell(cell) do
    sector = div(cell, 32)
    rem32 = rem(cell, 32)
    {sector, div(rem32, 8), rem(rem32, 8)}
  end

  @doc "Returns 0 for Dark squares (e.g. a1) and 1 for Light squares (e.g. d1, e4)."
  @spec square_parity(0..95) :: 0 | 1
  def square_parity(cell) do
    {_s, r, f} = from_cell(cell)
    band(r + f, 1)
  end

  @doc "Returns the 96-bit mask with bit `cell` set."
  @spec cell_bit(0..95) :: non_neg_integer()
  def cell_bit(cell), do: 1 <<< cell

  @doc "Full 96-bit all-ones mask."
  @spec mask96() :: non_neg_integer()
  def mask96, do: @mask96

  @doc "Returns the facing opposing sector across the rank-3 frontier."
  @spec facing_sector(0..2, 0..7) :: 0..2
  def facing_sector(sector, file), do: Builder.facing_sector(sector, file)

  @doc "Returns the mirrored file index across the rank-3 frontier."
  @spec facing_file(0..7) :: 0..7
  def facing_file(file), do: Builder.facing_file(file)

  @doc "Formats a cell index into human-readable sector algebraic notation (e.g. W:e4)."
  @spec cell_label(0..95) :: String.t()
  def cell_label(cell) do
    {s, r, f} = from_cell(cell)

    prefix =
      case s do
        0 -> "W"
        1 -> "R"
        2 -> "B"
      end

    file_char = <<?a + f>>
    "#{prefix}:#{file_char}#{r + 1}"
  end

  @doc "Fast count-trailing-zeros (least-significant set bit index) for non-zero 96-bit integers."
  @spec lsb_index(pos_integer()) :: 0..95
  def lsb_index(bb) when bb > 0 do
    w0 = bb &&& 0xFFFFFFFF

    if w0 != 0 do
      lsb32(w0)
    else
      w1 = (bb >>> 32) &&& 0xFFFFFFFF

      if w1 != 0 do
        32 + lsb32(w1)
      else
        64 + lsb32(bb >>> 64)
      end
    end
  end

  defp lsb32(w) do
    lo16 = w &&& 0xFFFF

    if lo16 != 0 do
      b0 = lo16 &&& 0xFF
      if b0 != 0, do: elem(@ctz8, b0), else: 8 + elem(@ctz8, lo16 >>> 8)
    else
      hi16 = w >>> 16
      b2 = hi16 &&& 0xFF
      if b2 != 0, do: 16 + elem(@ctz8, b2), else: 24 + elem(@ctz8, hi16 >>> 8)
    end
  end

  @doc "Population count of set bits in a 96-bit integer."
  @spec popcount(non_neg_integer()) :: non_neg_integer()
  def popcount(0), do: 0
  def popcount(bb), do: popcount_loop(bb, 0)

  defp popcount_loop(0, acc), do: acc
  defp popcount_loop(bb, acc), do: popcount_loop(bb &&& (bb - 1), acc + 1)

  @spec ortho_rays(0..95) :: {tuple(), tuple(), tuple(), tuple()}
  def ortho_rays(cell), do: elem(@ortho_rays, cell)

  @spec diag_rays(0..95) :: [{integer(), tuple()}]
  def diag_rays(cell), do: elem(@diag_rays, cell)

  @spec knight_attacks(0..95) :: non_neg_integer()
  def knight_attacks(cell), do: elem(@knight_attacks, cell)

  @spec king_attacks(0..95) :: non_neg_integer()
  def king_attacks(cell), do: elem(@king_attacks, cell)
end
