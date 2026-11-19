const std = @import("std");
const Io = std.Io;
const core = @import("three_chess");
const topo = core.topology;
const board = core.board;
const movegen = core.movegen;
const ai = core.ai;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file.interface;

    if (args.len > 1 and std.mem.eql(u8, args[1], "--serve")) {
        const port: u16 = if (args.len > 2) try std.fmt.parseInt(u16, args[2], 10) else 8080;
        const host: []const u8 = if (args.len > 3) args[3] else "0.0.0.0";
        try serveHttp(arena, io, out, host, port);
        return;
    }

    try runBenchmark(io, out);
    try out.flush();
}

fn runBenchmark(io: Io, out: anytype) !void {
    try out.print("3-Chess Zig u96 Engine Benchmark\n", .{});
    try out.print("================================\n", .{});

    const initial = board.GameState.initStandard();
    var depth: u8 = 1;
    while (depth <= 3) : (depth += 1) {
        const start = Io.Clock.Timestamp.now(io, .awake);
        const nodes = movegen.perft(&initial, depth);
        const elapsed_ns = start.untilNow(io).raw.nanoseconds;
        const elapsed_ms: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
        try out.print("Perft depth {d}: {d} nodes ({d:.2} ms)\n", .{ depth, nodes, elapsed_ms });
    }

    // Verify Option B Sudden Disappearance
    var demo = board.GameState.initEliminationDemo();
    const pre_occ = @popCount(demo.all_occ);
    const res = ai.searchBestMove(&demo, .paranoid, 2);
    if (res.best_move) |mv| {
        movegen.makeMoveAndAdvance(&demo, mv);
        const post_occ = @popCount(demo.all_occ);
        try out.print(
            "Sudden Disappearance Check: eliminated={any}, pre_pieces={d}, post_pieces={d}, alive_count={d}\n",
            .{ demo.last_eliminated_player, pre_occ, post_occ, demo.aliveCount() },
        );
    }

    // AI Self-Play Benchmark comparing MaxN vs Paranoid across phase transition
    inline for (.{ ai.SearchStrategy.maxn, ai.SearchStrategy.paranoid }) |strat| {
        var state = board.GameState.initStandard();
        var total_nodes: u64 = 0;
        const start = Io.Clock.Timestamp.now(io, .awake);
        var ply: usize = 0;
        while (!state.is_game_over and ply < 30) : (ply += 1) {
            const sr = ai.searchBestMove(&state, strat, 2);
            total_nodes += sr.nodes;
            if (sr.best_move) |mv| {
                movegen.makeMoveAndAdvance(&state, mv);
            } else break;
        }
        const elapsed_ns = @max(start.untilNow(io).raw.nanoseconds, 1);
        const elapsed_ms: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
        const nps: f64 = (@as(f64, @floatFromInt(total_nodes)) * 1_000_000_000.0) / @as(f64, @floatFromInt(elapsed_ns));
        try out.print(
            "Strategy {s}: {d} plies, {d} nodes in {d:.2} ms ({d:.0} nps)\n",
            .{ @tagName(strat), ply, total_nodes, elapsed_ms, nps },
        );
    }
}

fn serveHttp(arena: std.mem.Allocator, io: Io, out: anytype, host: []const u8, port: u16) !void {
    const addr = try Io.net.IpAddress.parse(host, port);
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    try out.print("3-Chess HTTP server listening on http://{s}:{d}/\n", .{ host, port });
    try out.flush();

    var req_buf: [4096]u8 = undefined;
    var w_buf: [4096]u8 = undefined;

    while (true) {
        const stream = try server.accept(io);
        defer stream.close(io);

        var rdr = stream.reader(io, &req_buf);
        const first_line = rdr.interface.takeDelimiterExclusive('\n') catch continue;
        var path: []const u8 = "/";
        var parts = std.mem.splitScalar(u8, std.mem.trimEnd(u8, first_line, "\r\n "), ' ');
        _ = parts.next();
        if (parts.next()) |raw_path| {
            path = raw_path;
        }

        const rel_file: []const u8 = if (std.mem.eql(u8, path, "/"))
            "web/index.html"
        else if (std.mem.eql(u8, path, "/style.css"))
            "web/style.css"
        else if (std.mem.eql(u8, path, "/app.js"))
            "web/app.js"
        else if (std.mem.eql(u8, path, "/3chess.wasm"))
            "web/3chess.wasm"
        else
            "";

        var wrt = stream.writer(io, &w_buf);
        if (rel_file.len == 0) {
            try wrt.interface.writeAll("HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\nConnection: close\r\n\r\nNot Found");
            try wrt.interface.flush();
            continue;
        }

        const contents = Io.Dir.cwd().readFileAlloc(io, rel_file, arena, .unlimited) catch {
            try wrt.interface.writeAll("HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\nConnection: close\r\n\r\nNot Found");
            try wrt.interface.flush();
            continue;
        };

        const ctype = if (std.mem.endsWith(u8, rel_file, ".html"))
            "text/html; charset=utf-8"
        else if (std.mem.endsWith(u8, rel_file, ".css"))
            "text/css; charset=utf-8"
        else if (std.mem.endsWith(u8, rel_file, ".js"))
            "application/javascript; charset=utf-8"
        else
            "application/wasm";

        try wrt.interface.print(
            "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
            .{ ctype, contents.len },
        );
        try wrt.interface.writeAll(contents);
        try wrt.interface.flush();
    }
}
