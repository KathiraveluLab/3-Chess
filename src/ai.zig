const std = @import("std");
const topo = @import("topology.zig");
const board = @import("board.zig");
const movegen = @import("movegen.zig");

const GameState = board.GameState;
const Move = board.Move;
const PieceType = board.PieceType;
const MoveList = movegen.MoveList;

pub const SearchStrategy = enum(u2) {
    maxn = 0,
    paranoid = 1,
};

pub const SearchResult = struct {
    best_move: ?Move,
    score: i32,
    nodes: u64,
};

const piece_values = [6]i32{ 100, 320, 330, 500, 900, 0 };

const center_rosette_mask: u96 = computeCenterMask();

fn computeCenterMask() u96 {
    var mask: u96 = 0;
    for (0..3) |s| {
        for (2..4) |r| {
            for (2..6) |f| {
                mask |= topo.cellBit(topo.toCell(@intCast(s), @intCast(r), @intCast(f)));
            }
        }
    }
    return mask;
}

pub fn evaluateTuple(state: *const GameState) [3]i32 {
    var raw = [3]i32{ 0, 0, 0 };

    for (0..3) |p_idx| {
        const p: u2 = @intCast(p_idx);
        if (!state.isAlive(p)) {
            raw[p_idx] = 0;
            continue;
        }
        var score: i32 = 10_000;
        for (0..5) |t_idx| {
            var bb = state.pieces[p_idx][t_idx];
            const val = piece_values[t_idx];
            while (bb != 0) {
                const sq: u7 = @intCast(@ctz(bb));
                bb &= bb - 1;
                score += val;
                if ((center_rosette_mask & topo.cellBit(sq)) != 0) {
                    score += 18;
                }
                if (t_idx == @intFromEnum(PieceType.pawn)) {
                    const c = topo.fromCell(sq);
                    if (c.sector == p) {
                        score += @as(i32, c.rank) * 8;
                    } else {
                        score += (4 - @as(i32, c.rank)) * 22;
                    }
                }
            }
        }
        if (movegen.isInCheck(state, p)) {
            score -= 45;
        }
        raw[p_idx] = score;
    }

    var rel = [3]i32{ 0, 0, 0 };
    for (0..3) |p| {
        if (!state.isAlive(@intCast(p))) {
            rel[p] = -20_000;
            continue;
        }
        var opp_sum: i32 = 0;
        for (0..3) |o| {
            if (o != p) {
                opp_sum += raw[o];
            }
        }
        rel[p] = raw[p] - @divTrunc(opp_sum, 2);
    }
    return rel;
}

fn scoreMoveOrder(state: *const GameState, mv: Move) i32 {
    var score: i32 = 0;
    if (state.pieceAt(mv.to)) |victim| {
        score += 10 * piece_values[@intFromEnum(victim.piece_type)] + 100;
    }
    if (mv.promo != 0) {
        score += piece_values[mv.promo] + 200;
    }
    if ((center_rosette_mask & topo.cellBit(mv.to)) != 0) {
        score += 25;
    }
    return score;
}

fn sortMoves(state: *const GameState, list: *MoveList) void {
    var scores: [256]i32 = undefined;
    for (0..list.len) |i| {
        scores[i] = scoreMoveOrder(state, list.items[i]);
    }
    var i: usize = 1;
    while (i < list.len) : (i += 1) {
        const key_mv = list.items[i];
        const key_sc = scores[i];
        var j: usize = i;
        while (j > 0 and scores[j - 1] < key_sc) : (j -= 1) {
            list.items[j] = list.items[j - 1];
            scores[j] = scores[j - 1];
        }
        list.items[j] = key_mv;
        scores[j] = key_sc;
    }
}

pub fn searchBestMove(state: *const GameState, strategy: SearchStrategy, depth: u8) SearchResult {
    var nodes: u64 = 0;
    const root_player = state.side_to_move;

    if (state.is_game_over) {
        return .{ .best_move = null, .score = 0, .nodes = 0 };
    }

    var list = MoveList{};
    movegen.generateLegalMoves(state, root_player, &list);
    if (list.len == 0) {
        return .{ .best_move = null, .score = 0, .nodes = 0 };
    }
    sortMoves(state, &list);

    // Phase 2: Automatic transition to 2-player Alpha-Beta after first elimination
    if (state.aliveCount() == 2) {
        var best_mv = list.items[0];
        var best_score: i32 = -1_000_000;
        const alpha: i32 = -1_000_000;
        const beta: i32 = 1_000_000;
        var a = alpha;

        for (list.items[0..list.len]) |mv| {
            var child = state.*;
            movegen.makeMoveAndAdvance(&child, mv);
            const sc = -alphaBeta2P(&child, depth -| 1, -beta, -a, &nodes);
            if (sc > best_score) {
                best_score = sc;
                best_mv = mv;
            }
            if (sc > a) a = sc;
        }
        return .{ .best_move = best_mv, .score = best_score, .nodes = nodes };
    }

    // Phase 1: 3-Player MaxN or Paranoid Search
    var best_mv = list.items[0];
    var best_score: i32 = -1_000_000;

    if (strategy == .maxn) {
        for (list.items[0..list.len]) |mv| {
            var child = state.*;
            movegen.makeMoveAndAdvance(&child, mv);
            const tuple = maxNSearch(&child, depth -| 1, &nodes);
            if (tuple[root_player] > best_score) {
                best_score = tuple[root_player];
                best_mv = mv;
            }
        }
    } else {
        var alpha: i32 = -1_000_000;
        const beta: i32 = 1_000_000;
        for (list.items[0..list.len]) |mv| {
            var child = state.*;
            movegen.makeMoveAndAdvance(&child, mv);
            const sc = paranoidSearch(&child, root_player, depth -| 1, alpha, beta, &nodes);
            if (sc > best_score) {
                best_score = sc;
                best_mv = mv;
            }
            if (sc > alpha) alpha = sc;
        }
    }

    return .{ .best_move = best_mv, .score = best_score, .nodes = nodes };
}

fn alphaBeta2P(state: *const GameState, depth: u8, alpha_in: i32, beta: i32, nodes: *u64) i32 {
    nodes.* += 1;
    const stm = state.side_to_move;

    if (state.is_game_over) {
        if (state.winner) |w| {
            return if (w == stm) 50_000 + @as(i32, depth) * 10 else -50_000 - @as(i32, depth) * 10;
        }
        return 0;
    }
    if (depth == 0) {
        return evaluateTuple(state)[stm];
    }

    var list = MoveList{};
    movegen.generateLegalMoves(state, stm, &list);
    if (list.len == 0) {
        return evaluateTuple(state)[stm];
    }
    sortMoves(state, &list);

    var alpha = alpha_in;
    var best: i32 = -1_000_000;
    for (list.items[0..list.len]) |mv| {
        var child = state.*;
        movegen.makeMoveAndAdvance(&child, mv);
        const sc = -alphaBeta2P(&child, depth - 1, -beta, -alpha, nodes);
        if (sc > best) best = sc;
        if (sc > alpha) alpha = sc;
        if (alpha >= beta) break;
    }
    return best;
}

fn maxNSearch(state: *const GameState, depth: u8, nodes: *u64) [3]i32 {
    nodes.* += 1;
    if (state.is_game_over or depth == 0) {
        return evaluateTuple(state);
    }

    const stm = state.side_to_move;
    var list = MoveList{};
    movegen.generateLegalMoves(state, stm, &list);
    if (list.len == 0) {
        return evaluateTuple(state);
    }
    sortMoves(state, &list);

    var best_tuple = [3]i32{ -1_000_000, -1_000_000, -1_000_000 };
    var first = true;
    const cap = @min(list.len, 24);
    for (list.items[0..cap]) |mv| {
        var child = state.*;
        movegen.makeMoveAndAdvance(&child, mv);
        const tuple = maxNSearch(&child, depth - 1, nodes);
        if (first or tuple[stm] > best_tuple[stm]) {
            best_tuple = tuple;
            first = false;
        }
    }
    return best_tuple;
}

fn paranoidSearch(state: *const GameState, root_player: u2, depth: u8, alpha_in: i32, beta_in: i32, nodes: *u64) i32 {
    nodes.* += 1;
    if (state.is_game_over or !state.isAlive(root_player) or depth == 0) {
        return evaluateTuple(state)[root_player];
    }

    const stm = state.side_to_move;
    var list = MoveList{};
    movegen.generateLegalMoves(state, stm, &list);
    if (list.len == 0) {
        return evaluateTuple(state)[root_player];
    }
    sortMoves(state, &list);

    var alpha = alpha_in;
    var beta = beta_in;

    if (stm == root_player) {
        var best: i32 = -1_000_000;
        for (list.items[0..list.len]) |mv| {
            var child = state.*;
            movegen.makeMoveAndAdvance(&child, mv);
            const sc = paranoidSearch(&child, root_player, depth - 1, alpha, beta, nodes);
            if (sc > best) best = sc;
            if (sc > alpha) alpha = sc;
            if (alpha >= beta) break;
        }
        return best;
    } else {
        var best: i32 = 1_000_000;
        for (list.items[0..list.len]) |mv| {
            var child = state.*;
            movegen.makeMoveAndAdvance(&child, mv);
            const sc = paranoidSearch(&child, root_player, depth - 1, alpha, beta, nodes);
            if (sc < best) best = sc;
            if (sc < beta) beta = sc;
            if (alpha >= beta) break;
        }
        return best;
    }
}

test "AI finds checkmating move causing army elimination in demo position" {
    const state = GameState.initEliminationDemo();
    const res = searchBestMove(&state, .paranoid, 2);
    try std.testing.expect(res.best_move != null);

    var after = state;
    movegen.makeMoveAndAdvance(&after, res.best_move.?);
    try std.testing.expect(!after.isAlive(1));
    try std.testing.expectEqual(@as(u96, 0), after.player_occ[1]);
}
