defmodule ThreeChess.Topology.Builder do
  @moduledoc """
  Compile-time lookup table builder for the 96-cell three-sector topology.
  Generates orthogonal rays, diagonal rays (including central rosette splits),
  knight attack bitmasks, and king attack bitmasks.
  """

  import Bitwise

  @num_cells 96

  @doc "Returns the facing opposing sector across the rank-3 frontier."
  def facing_sector(sector, file) when file < 4, do: rem(sector + 1, 3)
  def facing_sector(sector, _file), do: rem(sector + 2, 3)

  @doc "Returns the mirrored file index across the rank-3 frontier."
  def facing_file(file), do: 7 - file

  @doc "Steps one orthogonal unit in the local walk basis across sector boundaries."
  def step_basis_ortho({sector, rank, file, sr, sf}, local_dr, local_df) do
    dr = local_dr * sr
    df = local_df * sf
    nr = rank + dr
    nf = file + df

    cond do
      nf < 0 or nf > 7 or nr < 0 ->
        nil

      nr <= 3 ->
        {sector, nr, nf, sr, sf}

      true ->
        {facing_sector(sector, file), 3, facing_file(file), -sr, -sf}
    end
  end

  defp trace_ortho_ray(cur, dr, df, acc) when length(acc) < 8 do
    case step_basis_ortho(cur, dr, df) do
      nil ->
        List.to_tuple(Enum.reverse(acc))

      {ns, nr, nf, _, _} = nxt ->
        cell = ns * 32 + nr * 8 + nf
        trace_ortho_ray(nxt, dr, df, [cell | acc])
    end
  end

  defp trace_ortho_ray(_cur, _dr, _df, acc), do: List.to_tuple(Enum.reverse(acc))

  defp trace_diag_suffix(_s, _r, _f, _dr, _df, acc) when length(acc) >= 8 do
    List.to_tuple(Enum.reverse(acc))
  end

  defp trace_diag_suffix(s, r, f, dr, df, acc) do
    nr = r + dr
    nf = f + df

    if nf < 0 or nf > 7 or nr < 0 or nr > 3 do
      List.to_tuple(Enum.reverse(acc))
    else
      cell = s * 32 + nr * 8 + nf
      trace_diag_suffix(s, nr, nf, dr, df, [cell | acc])
    end
  end

  defp trace_diag_dir(_s, _r, _f, _dr, _df, acc) when length(acc) >= 8 do
    [List.to_tuple(Enum.reverse(acc))]
  end

  defp trace_diag_dir(s, r, f, dr, df, acc) do
    nr = r + dr
    nf = f + df

    cond do
      nf < 0 or nf > 7 or nr < 0 ->
        if acc == [], do: [], else: [List.to_tuple(Enum.reverse(acc))]

      nr <= 3 ->
        cell = s * 32 + nr * 8 + nf
        trace_diag_dir(s, nr, nf, dr, df, [cell | acc])

      true ->
        same_half = (f < 4 and nf < 4) or (f >= 4 and nf >= 4)

        if same_half do
          ns = facing_sector(s, f)
          next_f = 7 - nf
          cell = ns * 32 + 3 * 8 + next_f
          trace_diag_dir(ns, 3, next_f, -dr, -df, [cell | acc])
        else
          s1 = rem(s + 1, 3)
          s2 = rem(s + 2, 3)
          c1 = s1 * 32 + 3 * 8 + f
          c2 = s2 * 32 + 3 * 8 + f
          r1 = trace_diag_suffix(s1, 3, f, -dr, -df, [c1 | acc])
          r2 = trace_diag_suffix(s2, 3, f, -dr, -df, [c2 | acc])
          [r1, r2]
        end
    end
  end

  @doc "Builds the 96-element tuple of orthogonal ray tuples."
  def build_ortho_rays do
    List.to_tuple(
      for cell <- 0..(@num_cells - 1) do
        s = div(cell, 32)
        rem32 = rem(cell, 32)
        r = div(rem32, 8)
        f = rem(rem32, 8)
        start = {s, r, f, 1, 1}

        {
          trace_ortho_ray(start, 1, 0, []),
          trace_ortho_ray(start, -1, 0, []),
          trace_ortho_ray(start, 0, -1, []),
          trace_ortho_ray(start, 0, 1, [])
        }
      end
    )
  end

  @doc "Builds the 96-element tuple of diagonal ray lists."
  def build_diag_rays do
    List.to_tuple(
      for cell <- 0..(@num_cells - 1) do
        s = div(cell, 32)
        rem32 = rem(cell, 32)
        r = div(rem32, 8)
        f = rem(rem32, 8)

        for {dr, df} <- [{1, 1}, {1, -1}, {-1, 1}, {-1, -1}],
            ray <- trace_diag_dir(s, r, f, dr, df, []),
            tuple_size(ray) > 0 do
          {dr, ray}
        end
      end
    )
  end

  @doc "Builds the 96-element tuple of 96-bit knight attack masks."
  def build_knight_attacks do
    List.to_tuple(
      for cell <- 0..(@num_cells - 1) do
        s = div(cell, 32)
        rem32 = rem(cell, 32)
        r = div(rem32, 8)
        f = rem(rem32, 8)
        start = {s, r, f, 1, 1}

        axes = [{1, 0}, {-1, 0}, {0, 1}, {0, -1}]

        Enum.reduce(axes, 0, fn {adr, adf}, acc ->
          perps = if adr != 0, do: [{0, 1}, {0, -1}], else: [{1, 0}, {-1, 0}]

          case step_basis_ortho(start, adr, adf) do
            nil ->
              acc

            s1 ->
              acc_after_p1 =
                case step_basis_ortho(s1, adr, adf) do
                  nil ->
                    acc

                  s2 ->
                    Enum.reduce(perps, acc, fn {pdr, pdf}, a ->
                      case step_basis_ortho(s2, pdr, pdf) do
                        nil -> a
                        {ds, dr2, df2, _, _} -> a ||| (1 <<< (ds * 32 + dr2 * 8 + df2))
                      end
                    end)
                end

              Enum.reduce(perps, acc_after_p1, fn {pdr, pdf}, a ->
                case step_basis_ortho(s1, pdr, pdf) do
                  nil ->
                    a

                  p1 ->
                    case step_basis_ortho(p1, pdr, pdf) do
                      nil -> a
                      {ds, dr2, df2, _, _} -> a ||| (1 <<< (ds * 32 + dr2 * 8 + df2))
                    end
                end
              end)
          end
        end)
      end
    )
  end

  @doc "Builds the 96-element tuple of 96-bit king attack masks."
  def build_king_attacks(ortho_rays, diag_rays) do
    List.to_tuple(
      for cell <- 0..(@num_cells - 1) do
        ortho_tuple = elem(ortho_rays, cell)

        ortho_mask =
          Enum.reduce(0..3, 0, fn d, acc ->
            ray = elem(ortho_tuple, d)
            if tuple_size(ray) > 0, do: acc ||| (1 <<< elem(ray, 0)), else: acc
          end)

        diag_list = elem(diag_rays, cell)

        Enum.reduce(diag_list, ortho_mask, fn {_dr, ray}, acc ->
          if tuple_size(ray) > 0, do: acc ||| (1 <<< elem(ray, 0)), else: acc
        end)
      end
    )
  end
end
