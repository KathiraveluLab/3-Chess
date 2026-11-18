defmodule ThreeChessTest do
  use ExUnit.Case, async: false
  import Bitwise
  alias ThreeChess.{AI, Board, GameServer, HttpServer, MoveGen, Topology}

  test "96-cell coordinate mapping and parity invariants" do
    for cell <- 0..95 do
      {s, r, f} = Topology.from_cell(cell)
      assert Topology.to_cell(s, r, f) == cell
    end

    # Crossing central rank-3 frontier orthogonally always inverts square parity
    for s <- 0..2, f <- 0..7 do
      a = Topology.to_cell(s, 3, f)
      fwd_ray = elem(Topology.ortho_rays(a), 0)
      assert tuple_size(fwd_ray) > 0
      b = elem(fwd_ray, 0)
      assert Topology.square_parity(a) != Topology.square_parity(b)
      assert elem(elem(Topology.ortho_rays(b), 0), 0) == a
    end
  end

  test "diagonal rays preserve square parity and immediate diagonal adjacency is symmetric" do
    for a <- 0..95 do
      pa = Topology.square_parity(a)
      drays = Topology.diag_rays(a)

      for {_dr, ray} <- drays do
        for idx <- 0..(tuple_size(ray) - 1) do
          b = elem(ray, idx)
          assert Topology.square_parity(b) == pa
        end

        n = elem(ray, 0)
        n_rays = Topology.diag_rays(n)
        assert Enum.any?(n_rays, fn {_ndr, nray} -> elem(nray, 0) == a end)
      end
    end
  end

  test "central rosette squares d4 and e4 have 5 same-color diagonal neighbors across 3 sectors" do
    # White d4 (0, 3, 3) is Dark and reaches c3, e3, Red f4, Red d4, Black d4
    d4 = Topology.to_cell(0, 3, 3)
    diag_first = Topology.diag_rays(d4) |> Enum.map(fn {_dr, r} -> elem(r, 0) end) |> Enum.sort()

    expected =
      [
        Topology.to_cell(0, 2, 2),
        Topology.to_cell(0, 2, 4),
        Topology.to_cell(1, 3, 5),
        Topology.to_cell(1, 3, 3),
        Topology.to_cell(2, 3, 3)
      ]
      |> Enum.sort()

    assert diag_first == expected
  end

  test "knight and king attacks are symmetric and knight jumps invert color parity" do
    for a <- 0..95 do
      pa = Topology.square_parity(a)
      kmask = Topology.knight_attacks(a)

      for b <- 0..95, (kmask &&& (1 <<< b)) != 0 do
        assert Topology.square_parity(b) != pa
        assert (Topology.knight_attacks(b) &&& (1 <<< a)) != 0
      end

      gmask = Topology.king_attacks(a)

      for b <- 0..95, (gmask &&& (1 <<< b)) != 0 do
        assert (Topology.king_attacks(b) &&& (1 <<< a)) != 0
      end
    end
  end

  test "initial 96-cell board has 48 pieces and 20 legal moves for White" do
    state = Board.new()
    assert Topology.popcount(state.all_occ) == 48
    assert length(MoveGen.generate_legal_moves(state, 0)) == 20
    assert MoveGen.perft(state, 1) == 20
    assert MoveGen.perft(state, 2) == 400
  end

  test "pawn crossing frontier advances toward opposing back rank and promotes on rank 0" do
    state =
      %Board{castling: 0}
      |> Board.place_piece(0, 5, Topology.to_cell(0, 0, 4))
      |> Board.place_piece(1, 5, Topology.to_cell(1, 0, 7))
      |> Board.place_piece(2, 5, Topology.to_cell(2, 0, 7))
      |> Board.place_piece(0, 0, Topology.to_cell(1, 1, 0))

    moves = MoveGen.generate_legal_moves(state, 0)
    promos = Enum.filter(moves, fn {from, _to, promo, _c} -> from == Topology.to_cell(1, 1, 0) and promo != 0 end)
    assert length(promos) == 4
  end

  test "Option B sudden army disappearance removes all checkmated pieces and enters 2-player phase" do
    demo = Board.elimination_demo()
    pre_total = Topology.popcount(demo.all_occ)
    red_count = Topology.popcount(elem(demo.player_occ, 1))
    assert red_count == 6

    res = AI.search_best_move(demo, :paranoid, 2)
    assert res.best_move != nil

    after_state = MoveGen.make_move_and_advance(demo, res.best_move, true)
    assert not Board.alive?(after_state, 1)
    assert elem(after_state.player_occ, 1) == 0
    assert Board.alive_count(after_state) == 2
    assert Topology.popcount(after_state.all_occ) == pre_total - red_count
    assert after_state.last_eliminated_player == 1
    assert after_state.side_to_move == 2
    refute after_state.is_game_over

    # Verify AI transitions automatically to 2-Player Alpha-Beta
    p2_res = AI.search_best_move(after_state, :paranoid, 2)
    assert p2_res.phase == "2-Player Alpha-Beta"
    assert p2_res.best_move != nil
  end

  test "GameServer, HttpServer endpoints, and static web assets work end-to-end" do
    start_supervised!(GameServer)

    payload = GameServer.get_payload()
    assert length(payload.board) == 96
    assert length(payload.legal_moves) == 20
    assert payload.alive_count == 3
    assert length(payload.occ_hex) == 3

    _demo_payload = GameServer.load_demo()
    ai_res = GameServer.ai_move(:paranoid, 2)
    assert ai_res.ok
    assert ai_res.state.alive_count == 2
    assert ai_res.state.last_eliminated_player == 1
    assert ai_res.state.last_eliminated_piece_count == 6
    assert Enum.at(ai_res.state.occ_hex, 1) == "0x00000000_00000000_00000000"

    # Verify static web files exist and are non-empty
    for file <- ["web/index.html", "web/style.css", "web/app.js"] do
      assert File.exists?(file)
      assert byte_size(File.read!(file)) > 0
    end

    # Reset and verify HTTP routing + JSON serialization across endpoints
    _ = GameServer.reset()

    raw_state = HttpServer.process_raw_request("GET /api/state HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", "web")
    assert String.starts_with?(raw_state, "HTTP/1.1 200 OK")
    [_headers, json_body] = String.split(raw_state, "\r\n\r\n", parts: 2)
    {:ok, decoded} = JSON.decode(json_body)
    assert decoded["alive_count"] == 3
    assert length(decoded["legal_moves"]) == 20

    raw_html = HttpServer.process_raw_request("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", "web")
    assert String.starts_with?(raw_html, "HTTP/1.1 200 OK")
    assert String.contains?(raw_html, "text/html")

    demo_req = "POST /api/demo HTTP/1.1\r\nContent-Length: 0\r\n\r\n"
    raw_demo = HttpServer.process_raw_request(demo_req, "web")
    assert String.starts_with?(raw_demo, "HTTP/1.1 200 OK")

    ai_body = "{\"strategy\":\"paranoid\",\"depth\":2}"
    ai_req = "POST /api/ai_move HTTP/1.1\r\nContent-Length: #{byte_size(ai_body)}\r\n\r\n#{ai_body}"
    raw_ai = HttpServer.process_raw_request(ai_req, "web")
    assert String.starts_with?(raw_ai, "HTTP/1.1 200 OK")
    [_h2, ai_json] = String.split(raw_ai, "\r\n\r\n", parts: 2)
    {:ok, ai_decoded} = JSON.decode(ai_json)
    assert ai_decoded["ok"] == true
    assert ai_decoded["state"]["alive_count"] == 2
    assert ai_decoded["state"]["last_eliminated_player"] == 1
  end
end
