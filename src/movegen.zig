const std = @import("std");
const topo = @import("topology.zig");
const board = @import("board.zig");

const GameState = board.GameState;
const Move = board.Move;
const PieceType = board.PieceType;

pub const MoveList = struct {
    items: [256]Move = undefined,
    len: usize = 0,

    pub fn add(self: *MoveList, mv: Move) void {
        if (self.len < self.items.len) {
            self.items[self.len] = mv;
            self.len += 1;
        }
    }
};

pub fn isSquareAttackedBy(state: *const GameState, sq: u7, attacker: u2) bool {
    if (!state.isAlive(attacker)) return false;

    const sq_bit = topo.cellBit(sq);
    const att_pieces = &state.pieces[attacker];

    // King
    if ((topo.king_attacks[sq] & att_pieces[@intFromEnum(PieceType.king)]) != 0) {
        return true;
    }

    // Knight
    if ((topo.knight_attacks[sq] & att_pieces[@intFromEnum(PieceType.knight)]) != 0) {
        return true;
    }

    // Orthogonal sliders (Rook and Queen)
    const rook_queen = att_pieces[@intFromEnum(PieceType.rook)] | att_pieces[@intFromEnum(PieceType.queen)];
    if (rook_queen != 0) {
        for (0..4) |d| {
            const ray = topo.ortho_rays[sq][d];
            for (0..ray.len) |step| {
                const target = ray.cells[step];
                const tbit = topo.cellBit(target);
                if ((state.all_occ & tbit) != 0) {
                    if ((rook_queen & tbit) != 0) return true;
                    break;
                }
            }
        }
    }

    // Diagonal sliders (Bishop and Queen)
    const bishop_queen = att_pieces[@intFromEnum(PieceType.bishop)] | att_pieces[@intFromEnum(PieceType.queen)];
    if (bishop_queen != 0) {
        const dset = topo.diag_rays[sq];
        for (0..dset.count) |d| {
            const ray = dset.rays[d];
            for (0..ray.len) |step| {
                const target = ray.cells[step];
                const tbit = topo.cellBit(target);
                if ((state.all_occ & tbit) != 0) {
                    if ((bishop_queen & tbit) != 0) return true;
                    break;
                }
            }
        }
    }

    // Pawns owned by attacker: check every attacker pawn that can capture onto sq
    var pawns = att_pieces[@intFromEnum(PieceType.pawn)];
    while (pawns != 0) {
        const psq: u7 = @intCast(@ctz(pawns));
        pawns &= pawns - 1;
        if ((pawnCaptureMask(attacker, psq) & sq_bit) != 0) {
            return true;
        }
    }

    return false;
}

pub fn pawnCaptureMask(owner: u2, sq: u7) u96 {
    const c = topo.fromCell(sq);
    var mask: u96 = 0;

    if (c.sector == owner) {
        // Advancing toward the central frontier (+rank)
        const dset = topo.diag_rays[sq];
        for (0..dset.count) |d| {
            if (dset.init_dr[d] == 1 and dset.rays[d].len > 0) {
                mask |= topo.cellBit(dset.rays[d].cells[0]);
            }
        }
    } else {
        // Already crossed into an opponent's sector: moves toward that sector's back rank (-rank)
        if (c.rank > 0) {
            const nr: u2 = c.rank - 1;
            if (c.file > 0) mask |= topo.cellBit(topo.toCell(c.sector, nr, c.file - 1));
            if (c.file < 7) mask |= topo.cellBit(topo.toCell(c.sector, nr, c.file + 1));
        }
    }
    return mask;
}

pub fn isInCheck(state: *const GameState, player: u2) bool {
    if (!state.isAlive(player)) return false;
    const king_bb = state.pieces[player][@intFromEnum(PieceType.king)];
    if (king_bb == 0) return false;
    const king_sq: u7 = @intCast(@ctz(king_bb));

    for (0..3) |opp_idx| {
        const opp: u2 = @intCast(opp_idx);
        if (opp != player and isSquareAttackedBy(state, king_sq, opp)) {
            return true;
        }
    }
    return false;
}

fn isAttackedByAnyOpponent(state: *const GameState, sq: u7, player: u2) bool {
    for (0..3) |opp_idx| {
        const opp: u2 = @intCast(opp_idx);
        if (opp != player and isSquareAttackedBy(state, sq, opp)) {
            return true;
        }
    }
    return false;
}

pub fn applyRawMove(state: *GameState, player: u2, mv: Move) void {
    const moved_info = state.pieceAt(mv.from) orelse return;
    const ptype = moved_info.piece_type;

    // Capture if target occupied by an enemy
    if (state.pieceAt(mv.to)) |victim| {
        state.removePiece(victim.player, victim.piece_type, mv.to);
        // Clear castling right if corner rook is captured
        const vc = topo.fromCell(mv.to);
        if (vc.rank == 0) {
            if (vc.file == 7) state.castling &= ~(@as(u6, 1) << (@as(u3, victim.player) * 2));
            if (vc.file == 0) state.castling &= ~(@as(u6, 2) << (@as(u3, victim.player) * 2));
        }
    }

    state.removePiece(player, ptype, mv.from);

    const final_type: PieceType = if (mv.promo != 0) @enumFromInt(mv.promo) else ptype;
    state.placePiece(player, final_type, mv.to);

    if (mv.is_castle) {
        const tc = topo.fromCell(mv.to);
        if (tc.file == 6) {
            const rook_from = topo.toCell(player, 0, 7);
            const rook_to = topo.toCell(player, 0, 5);
            state.removePiece(player, .rook, rook_from);
            state.placePiece(player, .rook, rook_to);
        } else if (tc.file == 2) {
            const rook_from = topo.toCell(player, 0, 0);
            const rook_to = topo.toCell(player, 0, 3);
            state.removePiece(player, .rook, rook_from);
            state.placePiece(player, .rook, rook_to);
        }
    }

    // Update castling rights on king or rook movement
    if (ptype == .king) {
        state.castling &= ~(@as(u6, 0b11) << (@as(u3, player) * 2));
    } else if (ptype == .rook) {
        const fc = topo.fromCell(mv.from);
        if (fc.sector == player and fc.rank == 0) {
            if (fc.file == 7) state.castling &= ~(@as(u6, 1) << (@as(u3, player) * 2));
            if (fc.file == 0) state.castling &= ~(@as(u6, 2) << (@as(u3, player) * 2));
        }
    }
}

pub fn generatePseudoMoves(state: *const GameState, player: u2, list: *MoveList) void {
    list.len = 0;
    if (!state.isAlive(player)) return;

    const own_occ = state.player_occ[player];
    const enemy_occ = state.all_occ & ~own_occ;

    // 1. Pawns
    var pawns = state.pieces[player][@intFromEnum(PieceType.pawn)];
    while (pawns != 0) {
        const from: u7 = @intCast(@ctz(pawns));
        pawns &= pawns - 1;
        const c = topo.fromCell(from);

        if (c.sector == player) {
            // Single push toward central frontier (+rank)
            const fwd_ray = topo.ortho_rays[from][0];
            if (fwd_ray.len > 0) {
                const push1 = fwd_ray.cells[0];
                if ((state.all_occ & topo.cellBit(push1)) == 0) {
                    list.add(.{ .from = from, .to = push1 });
                    // Double push from starting pawn rank 1 -> 3 inside own sector
                    if (c.rank == 1 and fwd_ray.len > 1) {
                        const push2 = fwd_ray.cells[1];
                        if ((state.all_occ & topo.cellBit(push2)) == 0) {
                            list.add(.{ .from = from, .to = push2 });
                        }
                    }
                }
            }
        } else if (c.rank > 0) {
            // Advancing toward enemy back rank (-rank)
            const push1 = topo.toCell(c.sector, c.rank - 1, c.file);
            if ((state.all_occ & topo.cellBit(push1)) == 0) {
                if (c.rank - 1 == 0) {
                    addPromotions(list, from, push1);
                } else {
                    list.add(.{ .from = from, .to = push1 });
                }
            }
        }

        // Captures
        var caps = pawnCaptureMask(player, from) & enemy_occ;
        while (caps != 0) {
            const to: u7 = @intCast(@ctz(caps));
            caps &= caps - 1;
            const tc = topo.fromCell(to);
            if (c.sector != player and tc.sector == c.sector and tc.rank == 0) {
                addPromotions(list, from, to);
            } else {
                list.add(.{ .from = from, .to = to });
            }
        }
    }

    // 2. Knights
    var knights = state.pieces[player][@intFromEnum(PieceType.knight)];
    while (knights != 0) {
        const from: u7 = @intCast(@ctz(knights));
        knights &= knights - 1;
        var targets = topo.knight_attacks[from] & ~own_occ;
        while (targets != 0) {
            const to: u7 = @intCast(@ctz(targets));
            targets &= targets - 1;
            list.add(.{ .from = from, .to = to });
        }
    }

    // 3. Bishops
    var bishops = state.pieces[player][@intFromEnum(PieceType.bishop)];
    while (bishops != 0) {
        const from: u7 = @intCast(@ctz(bishops));
        bishops &= bishops - 1;
        emitDiagMoves(state, own_occ, from, list);
    }

    // 4. Rooks
    var rooks = state.pieces[player][@intFromEnum(PieceType.rook)];
    while (rooks != 0) {
        const from: u7 = @intCast(@ctz(rooks));
        rooks &= rooks - 1;
        emitOrthoMoves(state, own_occ, from, list);
    }

    // 5. Queens
    var queens = state.pieces[player][@intFromEnum(PieceType.queen)];
    while (queens != 0) {
        const from: u7 = @intCast(@ctz(queens));
        queens &= queens - 1;
        emitOrthoMoves(state, own_occ, from, list);
        emitDiagMoves(state, own_occ, from, list);
    }

    // 6. King + Castling
    var kings = state.pieces[player][@intFromEnum(PieceType.king)];
    while (kings != 0) {
        const from: u7 = @intCast(@ctz(kings));
        kings &= kings - 1;
        var targets = topo.king_attacks[from] & ~own_occ;
        while (targets != 0) {
            const to: u7 = @intCast(@ctz(targets));
            targets &= targets - 1;
            list.add(.{ .from = from, .to = to });
        }

        // Castling
        const ks_bit: u6 = @as(u6, 1) << (@as(u3, player) * 2);
        const qs_bit: u6 = @as(u6, 2) << (@as(u3, player) * 2);
        const k_home = topo.toCell(player, 0, 4);
        if (from == k_home and (state.castling & (ks_bit | qs_bit)) != 0 and !isAttackedByAnyOpponent(state, k_home, player)) {
            if ((state.castling & ks_bit) != 0) {
                const f1 = topo.toCell(player, 0, 5);
                const g1 = topo.toCell(player, 0, 6);
                const h1 = topo.toCell(player, 0, 7);
                const rook_ok = (state.pieces[player][@intFromEnum(PieceType.rook)] & topo.cellBit(h1)) != 0;
                const empty_ok = (state.all_occ & (topo.cellBit(f1) | topo.cellBit(g1))) == 0;
                if (rook_ok and empty_ok and !isAttackedByAnyOpponent(state, f1, player)) {
                    list.add(.{ .from = from, .to = g1, .is_castle = true });
                }
            }
            if ((state.castling & qs_bit) != 0) {
                const b1 = topo.toCell(player, 0, 1);
                const c1 = topo.toCell(player, 0, 2);
                const d1 = topo.toCell(player, 0, 3);
                const a1 = topo.toCell(player, 0, 0);
                const rook_ok = (state.pieces[player][@intFromEnum(PieceType.rook)] & topo.cellBit(a1)) != 0;
                const empty_ok = (state.all_occ & (topo.cellBit(b1) | topo.cellBit(c1) | topo.cellBit(d1))) == 0;
                if (rook_ok and empty_ok and !isAttackedByAnyOpponent(state, d1, player)) {
                    list.add(.{ .from = from, .to = c1, .is_castle = true });
                }
            }
        }
    }
}

fn addPromotions(list: *MoveList, from: u7, to: u7) void {
    list.add(.{ .from = from, .to = to, .promo = @intFromEnum(PieceType.queen) });
    list.add(.{ .from = from, .to = to, .promo = @intFromEnum(PieceType.rook) });
    list.add(.{ .from = from, .to = to, .promo = @intFromEnum(PieceType.bishop) });
    list.add(.{ .from = from, .to = to, .promo = @intFromEnum(PieceType.knight) });
}

fn emitOrthoMoves(state: *const GameState, own_occ: u96, from: u7, list: *MoveList) void {
    for (0..4) |d| {
        const ray = topo.ortho_rays[from][d];
        for (0..ray.len) |step| {
            const to = ray.cells[step];
            const tbit = topo.cellBit(to);
            if ((own_occ & tbit) != 0) break;
            list.add(.{ .from = from, .to = to });
            if ((state.all_occ & tbit) != 0) break;
        }
    }
}

fn emitDiagMoves(state: *const GameState, own_occ: u96, from: u7, list: *MoveList) void {
    var seen_targets: u96 = 0;
    const dset = topo.diag_rays[from];
    for (0..dset.count) |d| {
        const ray = dset.rays[d];
        for (0..ray.len) |step| {
            const to = ray.cells[step];
            const tbit = topo.cellBit(to);
            if ((own_occ & tbit) != 0) break;
            if ((seen_targets & tbit) == 0) {
                seen_targets |= tbit;
                list.add(.{ .from = from, .to = to });
            }
            if ((state.all_occ & tbit) != 0) break;
        }
    }
}

pub fn generateLegalMoves(state: *const GameState, player: u2, list: *MoveList) void {
    var pseudo = MoveList{};
    generatePseudoMoves(state, player, &pseudo);
    list.len = 0;

    for (pseudo.items[0..pseudo.len]) |mv| {
        var next_state = state.*;
        applyRawMove(&next_state, player, mv);
        if (!isInCheck(&next_state, player)) {
            list.add(mv);
        }
    }
}

fn nextAlivePlayer(state: *const GameState, current: u2) u2 {
    var candidate: u2 = @intCast((@as(u8, current) + 1) % 3);
    for (0..3) |_| {
        if (state.isAlive(candidate)) return candidate;
        candidate = @intCast((@as(u8, candidate) + 1) % 3);
    }
    return current;
}

/// Applies a verified legal move and handles Option B sudden army disappearance
/// when the next active player has zero legal moves (checkmate or 3-player stalemate).
pub fn makeMoveAndAdvance(state: *GameState, mv: Move) void {
    state.last_eliminated_player = null;
    state.last_eliminated_piece_count = 0;

    const mover = state.side_to_move;
    applyRawMove(state, mover, mv);
    state.ply += 1;

    var cur = nextAlivePlayer(state, mover);

    // Resolve checkmates / discovered checkmates cascading across surviving players
    var safety: usize = 0;
    while (safety < 3) : (safety += 1) {
        if (state.aliveCount() <= 1) {
            state.is_game_over = true;
            state.winner = findSoleSurvivor(state);
            state.side_to_move = state.winner orelse mover;
            return;
        }

        var legal = MoveList{};
        generateLegalMoves(state, cur, &legal);
        if (legal.len > 0) {
            state.side_to_move = cur;
            return;
        }

        const in_chk = isInCheck(state, cur);
        if (in_chk) {
            // Option B: Checkmated player's remaining pieces vanish immediately
            _ = state.eliminateArmy(cur);
            if (state.aliveCount() == 1) {
                state.is_game_over = true;
                state.winner = findSoleSurvivor(state);
                state.side_to_move = state.winner orelse mover;
                return;
            }
            cur = nextAlivePlayer(state, cur);
        } else {
            // Stalemate
            if (state.aliveCount() == 2) {
                state.is_game_over = true;
                state.winner = null;
                state.side_to_move = cur;
                return;
            } else {
                // In 3-player mode, remove stalemated army and continue between remaining 2
                _ = state.eliminateArmy(cur);
                cur = nextAlivePlayer(state, cur);
            }
        }
    }
}

fn findSoleSurvivor(state: *const GameState) ?u2 {
    for (0..3) |p_idx| {
        const p: u2 = @intCast(p_idx);
        if (state.isAlive(p)) return p;
    }
    return null;
}

pub fn perft(state: *const GameState, depth: u8) u64 {
    if (depth == 0 or state.is_game_over) return 1;
    var list = MoveList{};
    generateLegalMoves(state, state.side_to_move, &list);
    if (depth == 1) return @intCast(list.len);

    var nodes: u64 = 0;
    for (list.items[0..list.len]) |mv| {
        var child = state.*;
        makeMoveAndAdvance(&child, mv);
        nodes += perft(&child, depth - 1);
    }
    return nodes;
}

test "initial position has 20 legal moves for white" {
    const state = GameState.initStandard();
    var list = MoveList{};
    generateLegalMoves(&state, 0, &list);
    try std.testing.expectEqual(@as(usize, 20), list.len);
}

test "sudden disappearance removes checkmated army and transitions to 2-player phase" {
    var state = GameState.initEliminationDemo();
    const initial_total = @popCount(state.all_occ);
    const red_count = @popCount(state.player_occ[1]);
    try std.testing.expect(red_count >= 5);

    // White Queen at (1, 2, 5) moves to (1, 1, 6) delivering checkmate to Red King at (1, 0, 7)
    const mv = Move{
        .from = topo.toCell(1, 2, 5),
        .to = topo.toCell(1, 1, 6),
    };
    makeMoveAndAdvance(&state, mv);

    try std.testing.expect(!state.isAlive(1));
    try std.testing.expectEqual(@as(u96, 0), state.player_occ[1]);
    try std.testing.expectEqual(@as(u8, 2), state.aliveCount());
    try std.testing.expectEqual(initial_total - red_count, @popCount(state.all_occ));
    try std.testing.expectEqual(@as(?u2, 1), state.last_eliminated_player);
    try std.testing.expectEqual(@as(u2, 2), state.side_to_move);
    try std.testing.expect(!state.is_game_over);
}
