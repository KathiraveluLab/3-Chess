# 3-Chess

3-Chess is a three-player chess engine and interactive light-theme web application for **White**, **Red**, and **Black** played on a **96-cell three-sector hexagonal-perimeter board**.

## Game Rules and Topology

- **Board Geometry:** A regular outer hexagon partitioned into three 8x4 quadrilateral sectors (32 squares per sector, 96 cells total) converging at a 6-cell central rosette.
- **Armies and Turn Order:** White (Sector 0), Red (Sector 1), and Black (Sector 2) each start with an orthodox 16-piece army on ranks 0 and 1, rotating clockwise (`White -> Red -> Black`).
- **Orthodox Piece Movement:**
  - Orthogonal files and ranks cross the central rank-3 frontier from `(sector, 3, file)` into the facing sector `(facing_sector, 3, 7 - file)`, strictly inverting square parity.
  - Diagonal rays preserve square parity across every frontier and split into two matching-color branches at the central 6-cell rosette vertex between `d4` and `e4`.
  - Pawns advance toward the center inside their home sector (with optional two-square opening push from rank 1 to rank 3), cross the frontier, advance toward that opposing sector's back rank (rank 0), and promote upon reaching rank 0.
  - Kingside and queenside castling are supported on each player's home rank.
- **Sudden Army Disappearance (Elimination Rule):**
  - Last player standing wins.
  - Whenever a player is checkmated, all of that checkmated player's remaining pieces are immediately removed from the 96-cell board in a single bitmask clear, dynamically opening lines of sight and transitioning play to a two-player endgame between the surviving armies.

## Repository Architecture

### 1. Zig `u96` Bitboard Engine and WebAssembly Target (`build.zig`, `src/`)

- `src/topology.zig`: Native 96-bit (`u96`) cell masks and `comptime`-generated orthogonal rays, branching diagonal rays, knight attack masks, and king attack masks.
- `src/board.zig`: `GameState` storing `[3][6]u96` piece bitboards, per-player `u96` occupancy masks, castling rights, and $O(1)$ army elimination.
- `src/movegen.zig`: Legal move generator, pin/check checks across surviving opponents, sudden-disappearance turn resolution, and Perft verification.
- `src/ai.zig`: Multi-player MaxN and Paranoid alpha-beta search with automatic phase transition to 2-player Negamax Alpha-Beta when two players remain.
- `src/wasm.zig` and `src/main.zig`: Freestanding WebAssembly (`wasm32-freestanding`) exports, native CLI benchmark runner, and static HTTP server.

### 2. Elixir/OTP 29 Engine, Benchmark, and Web Server (`mix.exs`, `lib/`, `web/`)

- `lib/three_chess/topology_builder.ex` and `lib/three_chess/topology.ex`: Compile-time 96-bit bitboard lookup tables and fast bit scanning for BEAM arbitrary-precision integers.
- `lib/three_chess/board.ex` and `lib/three_chess/movegen.ex`: 96-bit bitboard state management, legal move generation, Perft, and sudden-disappearance checkmate handling.
- `lib/three_chess/ai.ex`: MaxN, Paranoid, and 2-player Alpha-Beta search with node and timing telemetry.
- `lib/three_chess/game_server.ex` and `lib/three_chess/http_server.ex`: OTP `GenServer` match controller and zero-dependency HTTP/JSON server.
- `web/index.html`, `web/style.css`, and `web/app.js`: Clean light-theme SVG hexagonal-perimeter board with bilinearly interpolated quadrilateral cells, vector piece silhouettes, legal move highlights, live `u96` hexadecimal bitboard masks, an elimination ledger, and a 1-move Sudden-Elimination tactical demo.

## Running Tests, Benchmarks, and the Web UI

### Elixir/OTP 29 Runtime

Navigate to the project root directory before running these commands.

Run unit tests:

```powershell
mix test
```

Run Perft, Sudden Disappearance verification, and AI benchmarks:

```powershell
mix three_chess.bench
```

Start the interactive web interface (then open `http://127.0.0.1:8080/`):

```powershell
mix three_chess.serve
```

### Zig Toolchain (Optional Native / WASM Build)

On environments permitting unsigned Zig binaries:

```bash
zig build test
zig build run -- --benchmark
zig build
```
