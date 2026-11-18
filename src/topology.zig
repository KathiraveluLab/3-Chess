const std = @import("std");

pub const num_cells: usize = 96;
pub const num_players: usize = 3;

pub const Color = enum(u2) {
    white = 0,
    red = 1,
    black = 2,

    pub fn next(self: Color) Color {
        return @enumFromInt((@as(u2, @intFromEnum(self)) + 1) % 3);
    }

    pub fn name(self: Color) []const u8 {
        return switch (self) {
            .white => "White",
            .red => "Red",
            .black => "Black",
        };
    }
};

pub const Coord = struct {
    sector: u2,
    rank: u2,
    file: u3,
};

pub const Ray = struct {
    cells: [8]u7 = [_]u7{0} ** 8,
    len: u4 = 0,
};

pub const DiagRaySet = struct {
    rays: [6]Ray = [_]Ray{.{}} ** 6,
    count: u4 = 0,
    /// Initial rank delta (+1 toward center, -1 toward outer back rank) for each ray.
    init_dr: [6]i8 = [_]i8{0} ** 6,
};

pub fn toCell(sector: u2, rank: u2, file: u3) u7 {
    return @as(u7, sector) * 32 + @as(u7, rank) * 8 + @as(u7, file);
}

pub fn fromCell(cell: u7) Coord {
    return .{
        .sector = @intCast(cell / 32),
        .rank = @intCast((cell % 32) / 8),
        .file = @intCast(cell % 8),
    };
}

/// Returns 0 for Dark squares (e.g. a1), 1 for Light squares (e.g. d1, e4).
pub fn squareParity(cell: u7) u1 {
    const c = fromCell(cell);
    return @intCast((@as(u8, c.rank) + @as(u8, c.file)) & 1);
}

pub fn cellBit(cell: u7) u96 {
    return @as(u96, 1) << cell;
}

/// Returns the opposing sector across the central rank-3 frontier for a given sector and file.
pub fn facingSector(sector: u2, file: u3) u2 {
    if (file < 4) {
        return @intCast((@as(u8, sector) + 1) % 3);
    } else {
        return @intCast((@as(u8, sector) + 2) % 3);
    }
}

pub fn facingFile(file: u3) u3 {
    return 7 - file;
}

const WalkState = struct {
    sector: u2,
    rank: i8,
    file: i8,
    sr: i8, // +1 means increasing rank moves along walk vector
    sf: i8, // +1 means increasing file moves along walk vector
};

fn stepBasisOrtho(st: WalkState, local_dr: i8, local_df: i8) ?WalkState {
    const dr = local_dr * st.sr;
    const df = local_df * st.sf;
    const nr = st.rank + dr;
    const nf = st.file + df;

    if (nf < 0 or nf > 7 or nr < 0) return null;
    if (nr <= 3) {
        return .{
            .sector = st.sector,
            .rank = nr,
            .file = nf,
            .sr = st.sr,
            .sf = st.sf,
        };
    }

    // Crossing the central rank-3 frontier (nr == 4)
    const f_u3: u3 = @intCast(st.file);
    return .{
        .sector = facingSector(st.sector, f_u3),
        .rank = 3,
        .file = @intCast(facingFile(f_u3)),
        .sr = -st.sr,
        .sf = -st.sf,
    };
}

pub const ortho_rays: [96][4]Ray = initOrthoRays();
pub const diag_rays: [96]DiagRaySet = initDiagRays();
pub const knight_attacks: [96]u96 = initKnightAttacks();
pub const king_attacks: [96]u96 = initKingAttacks();

fn initOrthoRays() [96][4]Ray {
    @setEvalBranchQuota(100_000);
    var table: [96][4]Ray = undefined;
    const dirs = [4][2]i8{
        .{ 1, 0 }, // 0: forward (+rank)
        .{ -1, 0 }, // 1: backward (-rank)
        .{ 0, -1 }, // 2: left (-file)
        .{ 0, 1 }, // 3: right (+file)
    };

    for (0..96) |i| {
        const c = fromCell(@intCast(i));
        for (0..4) |d| {
            var ray = Ray{};
            var cur = WalkState{
                .sector = c.sector,
                .rank = @intCast(c.rank),
                .file = @intCast(c.file),
                .sr = 1,
                .sf = 1,
            };
            while (stepBasisOrtho(cur, dirs[d][0], dirs[d][1])) |nxt| {
                const cell = toCell(nxt.sector, @intCast(nxt.rank), @intCast(nxt.file));
                ray.cells[ray.len] = cell;
                ray.len += 1;
                cur = nxt;
                if (ray.len >= 8) break;
            }
            table[i][d] = ray;
        }
    }
    return table;
}

const DiagCursor = struct {
    sector: u2,
    rank: i8,
    file: i8,
    dr: i8,
    df: i8,
};

fn appendDiagSuffix(ray: *Ray, start_cur: DiagCursor) void {
    var cur = start_cur;
    while (ray.len < 8) {
        const nr = cur.rank + cur.dr;
        const nf = cur.file + cur.df;
        if (nf < 0 or nf > 7 or nr < 0) break;
        if (nr <= 3) {
            ray.cells[ray.len] = toCell(cur.sector, @intCast(nr), @intCast(nf));
            ray.len += 1;
            cur.rank = nr;
            cur.file = nf;
        } else {
            // Unreachable after a branch (dr becomes -1), handled by primary trace.
            break;
        }
    }
}

fn initDiagRays() [96]DiagRaySet {
    @setEvalBranchQuota(100_000);
    var table: [96]DiagRaySet = [_]DiagRaySet{.{}} ** 96;
    const dirs = [4][2]i8{
        .{ 1, 1 },
        .{ 1, -1 },
        .{ -1, 1 },
        .{ -1, -1 },
    };

    for (0..96) |i| {
        const c = fromCell(@intCast(i));
        var set = DiagRaySet{};

        for (0..4) |d| {
            var ray = Ray{};
            var cur = DiagCursor{
                .sector = c.sector,
                .rank = @intCast(c.rank),
                .file = @intCast(c.file),
                .dr = dirs[d][0],
                .df = dirs[d][1],
            };
            var branched = false;
            var branch_ray = Ray{};

            while (ray.len < 8) {
                const nr = cur.rank + cur.dr;
                const nf = cur.file + cur.df;
                if (nf < 0 or nf > 7 or nr < 0) break;

                if (nr <= 3) {
                    const cell = toCell(cur.sector, @intCast(nr), @intCast(nf));
                    ray.cells[ray.len] = cell;
                    ray.len += 1;
                    cur.rank = nr;
                    cur.file = nf;
                    continue;
                }

                // Crossing the central rank-3 frontier (nr == 4 and cur.rank == 3, cur.dr == +1).
                const same_half = (cur.file < 4 and nf < 4) or (cur.file >= 4 and nf >= 4);
                if (same_half) {
                    const f_u3: u3 = @intCast(cur.file);
                    const next_s = facingSector(cur.sector, f_u3);
                    const next_f: i8 = 7 - nf;
                    const cell = toCell(next_s, 3, @intCast(next_f));
                    ray.cells[ray.len] = cell;
                    ray.len += 1;
                    cur = .{
                        .sector = next_s,
                        .rank = 3,
                        .file = next_f,
                        .dr = -cur.dr,
                        .df = -cur.df,
                    };
                    continue;
                }

                // Central rosette split: hits the center vertex between d4 and e4.
                // Both opposing sectors share this center vertex with the same square parity.
                const s1: u2 = @intCast((@as(u8, cur.sector) + 1) % 3);
                const s2: u2 = @intCast((@as(u8, cur.sector) + 2) % 3);
                const target_f: u3 = @intCast(cur.file); // 3 for d4, 4 for e4

                branch_ray = ray;
                branched = true;

                const cell1 = toCell(s1, 3, target_f);
                if (ray.len < 8) {
                    ray.cells[ray.len] = cell1;
                    ray.len += 1;
                }
                appendDiagSuffix(&ray, .{
                    .sector = s1,
                    .rank = 3,
                    .file = @intCast(target_f),
                    .dr = -cur.dr,
                    .df = -cur.df,
                });

                const cell2 = toCell(s2, 3, target_f);
                if (branch_ray.len < 8) {
                    branch_ray.cells[branch_ray.len] = cell2;
                    branch_ray.len += 1;
                }
                appendDiagSuffix(&branch_ray, .{
                    .sector = s2,
                    .rank = 3,
                    .file = @intCast(target_f),
                    .dr = -cur.dr,
                    .df = -cur.df,
                });
                break;
            }

            if (ray.len > 0) {
                set.rays[set.count] = ray;
                set.init_dr[set.count] = dirs[d][0];
                set.count += 1;
            }
            if (branched and branch_ray.len > 0) {
                set.rays[set.count] = branch_ray;
                set.init_dr[set.count] = dirs[d][0];
                set.count += 1;
            }
        }
        table[i] = set;
    }
    return table;
}

fn initKnightAttacks() [96]u96 {
    @setEvalBranchQuota(100_000);
    var table: [96]u96 = [_]u96{0} ** 96;
    const axes = [4][2]i8{
        .{ 1, 0 },
        .{ -1, 0 },
        .{ 0, 1 },
        .{ 0, -1 },
    };

    for (0..96) |i| {
        const c = fromCell(@intCast(i));
        var mask: u96 = 0;
        const start = WalkState{
            .sector = c.sector,
            .rank = @intCast(c.rank),
            .file = @intCast(c.file),
            .sr = 1,
            .sf = 1,
        };

        for (axes) |ax| {
            // Perpendicular axes
            const perps = if (ax[0] != 0)
                [2][2]i8{ .{ 0, 1 }, .{ 0, -1 } }
            else
                [2][2]i8{ .{ 1, 0 }, .{ -1, 0 } };

            // Pattern 1: 2 steps along primary axis, then 1 step perpendicular
            if (stepBasisOrtho(start, ax[0], ax[1])) |s1| {
                if (stepBasisOrtho(s1, ax[0], ax[1])) |s2| {
                    for (perps) |p| {
                        if (stepBasisOrtho(s2, p[0], p[1])) |dst| {
                            mask |= cellBit(toCell(dst.sector, @intCast(dst.rank), @intCast(dst.file)));
                        }
                    }
                }
                // Pattern 2: 1 step along primary axis, then 2 steps perpendicular
                for (perps) |p| {
                    if (stepBasisOrtho(s1, p[0], p[1])) |p1| {
                        if (stepBasisOrtho(p1, p[0], p[1])) |dst| {
                            mask |= cellBit(toCell(dst.sector, @intCast(dst.rank), @intCast(dst.file)));
                        }
                    }
                }
            }
        }
        table[i] = mask;
    }
    return table;
}

fn initKingAttacks() [96]u96 {
    @setEvalBranchQuota(100_000);
    var table: [96]u96 = [_]u96{0} ** 96;
    for (0..96) |i| {
        var mask: u96 = 0;
        for (0..4) |d| {
            const ray = ortho_rays[i][d];
            if (ray.len > 0) mask |= cellBit(ray.cells[0]);
        }
        const dset = diag_rays[i];
        for (0..dset.count) |d| {
            if (dset.rays[d].len > 0) mask |= cellBit(dset.rays[d].cells[0]);
        }
        table[i] = mask;
    }
    return table;
}

test "topology cell indexing and square parity" {
    for (0..96) |i| {
        const cell: u7 = @intCast(i);
        const c = fromCell(cell);
        try std.testing.expectEqual(cell, toCell(c.sector, c.rank, c.file));
    }

    // Orthogonal adjacency across frontier always flips square parity
    for (0..3) |s| {
        for (0..8) |f| {
            const a = toCell(@intCast(s), 3, @intCast(f));
            const b = ortho_rays[a][0].cells[0];
            try std.testing.expect(squareParity(a) != squareParity(b));
            try std.testing.expectEqual(a, ortho_rays[b][0].cells[0]);
        }
    }
}

test "diagonal rays preserve square parity and symmetry" {
    for (0..96) |a_idx| {
        const a: u7 = @intCast(a_idx);
        const pa = squareParity(a);
        const dset = diag_rays[a];
        for (0..dset.count) |r_idx| {
            const ray = dset.rays[r_idx];
            for (0..ray.len) |step| {
                const b = ray.cells[step];
                try std.testing.expectEqual(pa, squareParity(b));
            }
            // Immediate diagonal neighbor must be symmetric
            const n = ray.cells[0];
            var found_back = false;
            const nset = diag_rays[n];
            for (0..nset.count) |nr| {
                if (nset.rays[nr].len > 0 and nset.rays[nr].cells[0] == a) {
                    found_back = true;
                    break;
                }
            }
            try std.testing.expect(found_back);
        }
    }
}

test "knight and king attacks are symmetric and color-valid" {
    for (0..96) |a_idx| {
        const a: u7 = @intCast(a_idx);
        const pa = squareParity(a);
        var kmask = knight_attacks[a];
        while (kmask != 0) {
            const b: u7 = @intCast(@ctz(kmask));
            kmask &= kmask - 1;
            try std.testing.expect(squareParity(b) != pa);
            try std.testing.expect((knight_attacks[b] & cellBit(a)) != 0);
        }

        var gmask = king_attacks[a];
        while (gmask != 0) {
            const b: u7 = @intCast(@ctz(gmask));
            gmask &= gmask - 1;
            try std.testing.expect((king_attacks[b] & cellBit(a)) != 0);
        }
    }
}
