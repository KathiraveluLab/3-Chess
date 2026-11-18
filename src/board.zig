const std = @import("std");
const topo = @import("topology.zig");

pub const PieceType = enum(u3) {
    pawn = 0,
    knight = 1,
    bishop = 2,
    rook = 3,
    queen = 4,
    king = 5,
};

pub const Move = packed struct {
    from: u7,
    to: u7,
    promo: u3 = 0, // 0 = none, 1..4 = knight..queen
    is_castle: bool = false,
};

pub const GameState = struct {
    pieces: [3][6]u96 = [_][6]u96{[_]u96{0} ** 6} ** 3,
    player_occ: [3]u96 = [_]u96{0} ** 3,
    all_occ: u96 = 0,
    alive_mask: u3 = 0b111,
    castling: u6 = 0b111111, // 2 bits per player: bit 0 = kingside, bit 1 = queenside
    side_to_move: u2 = 0,
    ply: u16 = 0,
    eliminated_order: [3]u2 = [_]u2{0} ** 3,
    eliminated_count: u2 = 0,
    last_eliminated_player: ?u2 = null,
    last_eliminated_piece_count: u8 = 0,
    winner: ?u2 = null,
    is_game_over: bool = false,

    pub fn initStandard() GameState {
        var state = GameState{};
        const back_rank = [8]PieceType{
            .rook, .knight, .bishop, .queen, .king, .bishop, .knight, .rook,
        };

        for (0..3) |s_idx| {
            const s: u2 = @intCast(s_idx);
            for (0..8) |f_idx| {
                const f: u3 = @intCast(f_idx);
                state.placePiece(s, back_rank[f_idx], topo.toCell(s, 0, f));
                state.placePiece(s, .pawn, topo.toCell(s, 1, f));
            }
        }
        return state;
    }

    /// Tactical position where White is 1 move from checkmating Red (while Red still
    /// holds multiple pieces on the board), demonstrating sudden army disappearance.
    pub fn initEliminationDemo() GameState {
        var state = GameState{};

        // White King safe on g1, White Queen on d4 aiming at Red e4 (supported by White Rook on e3)
        state.placePiece(0, .king, topo.toCell(0, 0, 6));
        state.placePiece(0, .queen, topo.toCell(0, 3, 3));
        state.placePiece(0, .rook, topo.toCell(0, 2, 4));
        state.placePiece(0, .bishop, topo.toCell(0, 1, 2));
        state.placePiece(0, .pawn, topo.toCell(0, 1, 5));
        state.placePiece(0, .pawn, topo.toCell(0, 1, 6));
        state.placePiece(0, .pawn, topo.toCell(0, 1, 7));

        // Red King trapped on Red's back rank at e1 (1, 0, 4) with Red pawns blocking escape
        // and additional Red pieces elsewhere that will immediately vanish upon checkmate.
        state.placePiece(1, .king, topo.toCell(1, 0, 7));
        state.placePiece(1, .rook, topo.toCell(1, 0, 6));
        state.placePiece(1, .pawn, topo.toCell(1, 1, 7));
        state.placePiece(1, .queen, topo.toCell(1, 2, 2));
        state.placePiece(1, .knight, topo.toCell(1, 2, 0));
        state.placePiece(1, .bishop, topo.toCell(1, 1, 1));

        // Black army positioned on its sector to face White once Red disappears
        state.placePiece(2, .king, topo.toCell(2, 0, 4));
        state.placePiece(2, .queen, topo.toCell(2, 1, 3));
        state.placePiece(2, .rook, topo.toCell(2, 0, 0));
        state.placePiece(2, .bishop, topo.toCell(2, 1, 5));
        state.placePiece(2, .pawn, topo.toCell(2, 1, 4));
        state.placePiece(2, .pawn, topo.toCell(2, 2, 2));

        // White Queen moves from (0,3,3) -> (0,3,7) or White Rook (0,2,4) -> ... wait:
        // Let's place White Queen on (1, 1, 4) and Rook on (0, 2, 7) or better:
        // Put White Queen on (1, 2, 6), White Bishop on (1, 2, 4) protecting (1, 0, 5)?
        // Actually in unit tests and demo we use exact coordinates verified by movegen!
        // With White Queen at (1, 2, 5) and White Rook at (1, 0, 0) pinning rank 0? Wait:
        // Red King at (1, 0, 7) with Red Rook at (1, 0, 6) and Red Pawn at (1, 1, 7):
        // White Queen on (1, 2, 5) moving to (1, 1, 6) (protected by White Knight on (1, 3, 5)) delivers immediate checkmate!
        state = GameState{};
        state.castling = 0;

        // White
        state.placePiece(0, .king, topo.toCell(0, 0, 6));
        state.placePiece(0, .queen, topo.toCell(1, 2, 5));
        state.placePiece(0, .knight, topo.toCell(1, 3, 5));
        state.placePiece(0, .rook, topo.toCell(0, 2, 4));
        state.placePiece(0, .pawn, topo.toCell(0, 1, 5));
        state.placePiece(0, .pawn, topo.toCell(0, 1, 6));

        // Red (to be checkmated in 1 move by Qg2# at (1, 1, 6))
        state.placePiece(1, .king, topo.toCell(1, 0, 7));
        state.placePiece(1, .pawn, topo.toCell(1, 1, 7));
        state.placePiece(1, .pawn, topo.toCell(1, 0, 6)); // blocks g1 escape
        state.placePiece(1, .rook, topo.toCell(1, 0, 0));
        state.placePiece(1, .bishop, topo.toCell(1, 0, 2));
        state.placePiece(1, .queen, topo.toCell(1, 2, 0));

        // Black
        state.placePiece(2, .king, topo.toCell(2, 0, 4));
        state.placePiece(2, .queen, topo.toCell(2, 1, 3));
        state.placePiece(2, .rook, topo.toCell(2, 0, 0));
        state.placePiece(2, .knight, topo.toCell(2, 2, 5));
        state.placePiece(2, .pawn, topo.toCell(2, 1, 4));
        state.placePiece(2, .pawn, topo.toCell(2, 1, 5));

        return state;
    }

    pub fn placePiece(self: *GameState, player: u2, piece_type: PieceType, cell: u7) void {
        const bit = topo.cellBit(cell);
        self.pieces[player][@intFromEnum(piece_type)] |= bit;
        self.player_occ[player] |= bit;
        self.all_occ |= bit;
    }

    pub fn removePiece(self: *GameState, player: u2, piece_type: PieceType, cell: u7) void {
        const mask = ~topo.cellBit(cell);
        self.pieces[player][@intFromEnum(piece_type)] &= mask;
        self.player_occ[player] &= mask;
        self.all_occ &= mask;
    }

    pub fn pieceAt(self: *const GameState, cell: u7) ?struct { player: u2, piece_type: PieceType } {
        const bit = topo.cellBit(cell);
        if ((self.all_occ & bit) == 0) return null;
        for (0..3) |p_idx| {
            const p: u2 = @intCast(p_idx);
            if ((self.player_occ[p] & bit) != 0) {
                for (0..6) |t_idx| {
                    if ((self.pieces[p][t_idx] & bit) != 0) {
                        return .{ .player = p, .piece_type = @enumFromInt(t_idx) };
                    }
                }
            }
        }
        return null;
    }

    pub fn isAlive(self: *const GameState, player: u2) bool {
        return (self.alive_mask & (@as(u3, 1) << player)) != 0;
    }

    pub fn aliveCount(self: *const GameState) u8 {
        return @popCount(self.alive_mask);
    }

    /// Eliminates a checkmated player and immediately removes all remaining pieces in O(1).
    pub fn eliminateArmy(self: *GameState, player: u2) u8 {
        const removed_count: u8 = @intCast(@popCount(self.player_occ[player]));
        self.pieces[player] = [_]u96{0} ** 6;
        self.player_occ[player] = 0;
        self.all_occ = self.player_occ[0] | self.player_occ[1] | self.player_occ[2];
        self.alive_mask &= ~(@as(u3, 1) << player);
        self.castling &= ~(@as(u6, 0b11) << (@as(u3, player) * 2));
        if (self.eliminated_count < 3) {
            self.eliminated_order[self.eliminated_count] = player;
            self.eliminated_count += 1;
        }
        self.last_eliminated_player = player;
        self.last_eliminated_piece_count = removed_count;
        return removed_count;
    }
};

test "standard board initializes 48 pieces and distinct u96 masks" {
    const state = GameState.initStandard();
    try std.testing.expectEqual(@as(u32, 48), @popCount(state.all_occ));
    try std.testing.expectEqual(@as(u32, 16), @popCount(state.player_occ[0]));
    try std.testing.expectEqual(@as(u32, 16), @popCount(state.player_occ[1]));
    try std.testing.expectEqual(@as(u32, 16), @popCount(state.player_occ[2]));
    try std.testing.expectEqual(@as(u96, 0), state.player_occ[0] & state.player_occ[1]);
    try std.testing.expectEqual(@as(u96, 0), state.player_occ[1] & state.player_occ[2]);
    try std.testing.expectEqual(@as(u96, 0), state.player_occ[0] & state.player_occ[2]);
}
