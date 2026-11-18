const core = @import("three_chess");
const topo = core.topology;
const board = core.board;
const movegen = core.movegen;
const ai = core.ai;

var global_state: board.GameState = board.GameState.initStandard();
var current_moves: movegen.MoveList = .{};
var last_ai_nodes: u32 = 0;

export fn wasm_init_game() void {
    global_state = board.GameState.initStandard();
    current_moves.len = 0;
    last_ai_nodes = 0;
}

export fn wasm_load_elimination_demo() void {
    global_state = board.GameState.initEliminationDemo();
    current_moves.len = 0;
    last_ai_nodes = 0;
}

export fn wasm_get_cell_piece(cell: u32) i32 {
    if (cell >= 96) return -1;
    const info = global_state.pieceAt(@intCast(cell)) orelse return -1;
    return @as(i32, info.player) * 8 + @as(i32, @intFromEnum(info.piece_type));
}

export fn wasm_get_legal_moves_from(cell: u32) u32 {
    if (cell >= 96 or global_state.is_game_over) return 0;
    var all = movegen.MoveList{};
    movegen.generateLegalMoves(&global_state, global_state.side_to_move, &all);

    current_moves.len = 0;
    for (all.items[0..all.len]) |mv| {
        if (mv.from == @as(u7, @intCast(cell))) {
            current_moves.add(mv);
        }
    }
    return @intCast(current_moves.len);
}

export fn wasm_get_legal_move_target(index: u32) u32 {
    if (index >= current_moves.len) return 0xFFFF;
    const mv = current_moves.items[index];
    return @as(u32, mv.to) | (@as(u32, mv.promo) << 8);
}

export fn wasm_make_move(from_cell: u32, to_cell: u32, promo: u32) u32 {
    if (from_cell >= 96 or to_cell >= 96 or global_state.is_game_over) return 0;
    var all = movegen.MoveList{};
    movegen.generateLegalMoves(&global_state, global_state.side_to_move, &all);

    for (all.items[0..all.len]) |mv| {
        if (mv.from == @as(u7, @intCast(from_cell)) and mv.to == @as(u7, @intCast(to_cell))) {
            if (mv.promo == 0 or promo == 0 or mv.promo == @as(u3, @intCast(promo))) {
                const chosen = if (mv.promo != 0 and promo == 0)
                    board.Move{ .from = mv.from, .to = mv.to, .promo = @intFromEnum(board.PieceType.queen), .is_castle = mv.is_castle }
                else
                    mv;
                movegen.makeMoveAndAdvance(&global_state, chosen);
                return 1;
            }
        }
    }
    return 0;
}

export fn wasm_ai_move(strategy_raw: u32, depth_raw: u32) i32 {
    if (global_state.is_game_over) return -1;
    const strat: ai.SearchStrategy = if (strategy_raw == 0) .maxn else .paranoid;
    const depth: u8 = @intCast(@min(@max(depth_raw, 1), 4));
    const res = ai.searchBestMove(&global_state, strat, depth);
    last_ai_nodes = @intCast(@min(res.nodes, 0xFFFF_FFFF));
    if (res.best_move) |mv| {
        movegen.makeMoveAndAdvance(&global_state, mv);
        return (@as(i32, mv.from) << 8) | @as(i32, mv.to);
    }
    return -1;
}

export fn wasm_get_side_to_move() u32 {
    return global_state.side_to_move;
}

export fn wasm_get_alive_mask() u32 {
    return global_state.alive_mask;
}

export fn wasm_is_game_over() u32 {
    return if (global_state.is_game_over) 1 else 0;
}

export fn wasm_get_winner() i32 {
    return if (global_state.winner) |w| @as(i32, w) else -1;
}

export fn wasm_is_in_check(player: u32) u32 {
    if (player >= 3) return 0;
    return if (movegen.isInCheck(&global_state, @intCast(player))) 1 else 0;
}

export fn wasm_get_last_eliminated() i32 {
    return if (global_state.last_eliminated_player) |p| @as(i32, p) else -1;
}

export fn wasm_get_occ_word(player: u32, word_idx: u32) u32 {
    if (player >= 3 or word_idx >= 3) return 0;
    const shift: u7 = @intCast(word_idx * 32);
    return @truncate(global_state.player_occ[player] >> shift);
}

export fn wasm_get_last_nodes() u32 {
    return last_ai_nodes;
}

export fn wasm_get_square_parity(cell: u32) u32 {
    if (cell >= 96) return 0;
    return topo.squareParity(@intCast(cell));
}
