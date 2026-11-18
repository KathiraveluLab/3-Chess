(function () {
  "use strict";

  const SVG_NS = "http://www.w3.org/2000/svg";
  const CX = 420;
  const CY = 420;
  const RADIUS = 345;
  const PLAYER_NAMES = ["White", "Red", "Black"];
  const PIECE_NAMES = ["Pawn", "Knight", "Bishop", "Rook", "Queen", "King"];
  const FILES = ["a", "b", "c", "d", "e", "f", "g", "h"];

  function hexVertex(deg) {
    const rad = (deg * Math.PI) / 180;
    return {
      x: CX + RADIUS * Math.cos(rad),
      y: CY + RADIUS * Math.sin(rad)
    };
  }

  function midpoint(a, b) {
    return { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 };
  }

  function bilerp(p00, p10, p01, p11, u, v) {
    const topX = (1 - u) * p00.x + u * p10.x;
    const topY = (1 - u) * p00.y + u * p10.y;
    const botX = (1 - u) * p01.x + u * p11.x;
    const botY = (1 - u) * p01.y + u * p11.y;
    return {
      x: (1 - v) * topX + v * botX,
      y: (1 - v) * topY + v * botY
    };
  }

  const V0 = hexVertex(60);   // bottom-right
  const V1 = hexVertex(120);  // bottom-left
  const V2 = hexVertex(180);  // left
  const V3 = hexVertex(240);  // top-left
  const V4 = hexVertex(300);  // top-right
  const V5 = hexVertex(0);    // right
  const C = { x: CX, y: CY };

  const B_W = midpoint(V1, V0);
  const M_WR = midpoint(V2, V1);
  const B_R = midpoint(V3, V2);
  const M_RB = midpoint(V4, V3);
  const B_B = midpoint(V5, V4);
  const M_BW = midpoint(V0, V5);

  const PATCHES = {
    "0-0": { p00: V1, p10: B_W, p01: M_WR, p11: C },
    "0-1": { p00: B_W, p10: V0, p01: C, p11: M_BW },
    "1-0": { p00: V3, p10: B_R, p01: M_RB, p11: C },
    "1-1": { p00: B_R, p10: V2, p01: C, p11: M_WR },
    "2-0": { p00: V5, p10: B_B, p01: M_BW, p11: C },
    "2-1": { p00: B_B, p10: V4, p01: C, p11: M_RB }
  };

  const CELL_GEOM = [];
  for (let cell = 0; cell < 96; cell++) {
    const sector = Math.floor(cell / 32);
    const rem32 = cell % 32;
    const rank = Math.floor(rem32 / 8);
    const file = rem32 % 8;
    const half = file < 4 ? 0 : 1;
    const patch = PATCHES[`${sector}-${half}`];

    const u0 = (file % 4) / 4;
    const u1 = ((file % 4) + 1) / 4;
    const v0 = rank / 4;
    const v1 = (rank + 1) / 4;

    const c00 = bilerp(patch.p00, patch.p10, patch.p01, patch.p11, u0, v0);
    const c10 = bilerp(patch.p00, patch.p10, patch.p01, patch.p11, u1, v0);
    const c11 = bilerp(patch.p00, patch.p10, patch.p01, patch.p11, u1, v1);
    const c01 = bilerp(patch.p00, patch.p10, patch.p01, patch.p11, u0, v1);

    const cx = (c00.x + c10.x + c11.x + c01.x) / 4;
    const cy = (c00.y + c10.y + c11.y + c01.y) / 4;
    const outerMid = midpoint(c00, c10);
    const parity = (rank + file) & 1;

    CELL_GEOM.push({
      cell,
      sector,
      rank,
      file,
      parity,
      cx,
      cy,
      outerMid,
      points: `${c00.x.toFixed(2)},${c00.y.toFixed(2)} ${c10.x.toFixed(2)},${c10.y.toFixed(2)} ${c11.x.toFixed(2)},${c11.y.toFixed(2)} ${c01.x.toFixed(2)},${c01.y.toFixed(2)}`
    });
  }

  // Vector piece silhouettes centered around (0, 0) in a ~30x30 box
  function createPieceSvg(owner, pieceType, cx, cy) {
    const g = document.createElementNS(SVG_NS, "g");
    g.setAttribute("transform", `translate(${cx.toFixed(2)}, ${cy.toFixed(2)}) scale(0.72)`);
    g.setAttribute("pointer-events", "none");

    const styles = [
      { fill: "#ffffff", stroke: "#0f172a", detail: "#0f172a" }, // White
      { fill: "#dc2626", stroke: "#7f1d1d", detail: "#ffffff" }, // Red
      { fill: "#1e293b", stroke: "#020617", detail: "#f8fafc" }  // Black
    ][owner];

    const addPath = (d, useDetail = false) => {
      const p = document.createElementNS(SVG_NS, "path");
      p.setAttribute("d", d);
      p.setAttribute("fill", useDetail ? styles.detail : styles.fill);
      p.setAttribute("stroke", useDetail ? styles.detail : styles.stroke);
      p.setAttribute("stroke-width", useDetail ? "1.1" : "1.8");
      p.setAttribute("stroke-linejoin", "round");
      p.setAttribute("stroke-linecap", "round");
      g.appendChild(p);
    };

    const addCircle = (x, y, r, useDetail = false) => {
      const c = document.createElementNS(SVG_NS, "circle");
      c.setAttribute("cx", x);
      c.setAttribute("cy", y);
      c.setAttribute("r", r);
      c.setAttribute("fill", useDetail ? styles.detail : styles.fill);
      c.setAttribute("stroke", useDetail ? styles.detail : styles.stroke);
      c.setAttribute("stroke-width", "1.6");
      g.appendChild(c);
    };

    switch (pieceType) {
      case 0: // Pawn
        addPath("M -9 13 L 9 13 L 8 9 L -8 9 Z");
        addPath("M -6 9 C -4 2, -3 -2, -2 -4 L 2 -4 C 3 -2, 4 2, 6 9 Z");
        addCircle(0, -8, 5);
        break;
      case 1: // Knight
        addPath("M -10 13 L 10 13 L 9 9 L -9 9 Z");
        addPath("M -7 9 C -8 1, -4 -6, 0 -10 L 1 -13 L 4 -10 C 8 -8, 10 -2, 8 4 L 2 2 C 3 5, 5 7, 7 9 Z");
        addCircle(3, -5, 1.3, true);
        break;
      case 2: // Bishop
        addPath("M -10 13 L 10 13 L 8 9 L -8 9 Z");
        addPath("M -6 9 C -7 1, -5 -6, 0 -10 C 5 -6, 7 1, 6 9 Z");
        addCircle(0, -13, 2.3);
        addPath("M -2 -3 L 2 -3 M 0 -5 L 0 -1", true);
        break;
      case 3: // Rook
        addPath("M -10 13 L 10 13 L 9 9 L -9 9 Z");
        addPath("M -7 9 L -6 -6 L -8 -6 L -8 -12 L -4 -12 L -4 -9 L -1.5 -9 L -1.5 -12 L 1.5 -12 L 1.5 -9 L 4 -9 L 4 -12 L 8 -12 L 8 -6 L 6 -6 L 7 9 Z");
        break;
      case 4: // Queen
        addPath("M -10 13 L 10 13 L 9 9 L -9 9 Z");
        addPath("M -8 9 L -11 -5 L -5 1 L 0 -9 L 5 1 L 11 -5 L 8 9 Z");
        addCircle(-11, -7, 1.8);
        addCircle(0, -11, 2);
        addCircle(11, -7, 1.8);
        break;
      case 5: // King
        addPath("M -10 13 L 10 13 L 9 9 L -9 9 Z");
        addPath("M -7 9 C -9 1, -6 -6, 0 -7 C 6 -6, 9 1, 7 9 Z");
        addPath("M -1.5 -7 L -1.5 -14 L -4 -14 L -4 -16.5 L -1.5 -16.5 L -1.5 -19 L 1.5 -19 L 1.5 -16.5 L 4 -16.5 L 4 -14 L 1.5 -14 L 1.5 -7 Z");
        break;
    }

    return g;
  }

  let gameState = null;
  let selectedCell = null;
  let autoPlayTimer = null;
  let busy = false;

  const boardSvg = document.getElementById("board-svg");
  const phaseBadge = document.getElementById("phase-badge");
  const turnBadge = document.getElementById("turn-badge");
  const plyBadge = document.getElementById("ply-badge");
  const selectionHint = document.getElementById("selection-hint");
  const telemetryLine = document.getElementById("telemetry-line");
  const elimBanner = document.getElementById("elimination-banner");
  const elimText = document.getElementById("elimination-text");
  const elimLog = document.getElementById("elimination-log");
  const moveHistoryEl = document.getElementById("move-history");
  const btnAutoPlay = document.getElementById("btn-autoplay");

  async function apiGet(url) {
    const res = await fetch(url);
    return res.json();
  }

  async function apiPost(url, payload = {}) {
    const res = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload)
    });
    return res.json();
  }

  function legalTargetsForCell(cell) {
    if (!gameState || !gameState.legal_moves) return [];
    const seen = new Set();
    const targets = [];
    for (const mv of gameState.legal_moves) {
      if (mv.from === cell && !seen.has(mv.to)) {
        seen.add(mv.to);
        targets.push(mv);
      }
    }
    return targets;
  }

  function renderBoard() {
    while (boardSvg.firstChild) {
      boardSvg.removeChild(boardSvg.firstChild);
    }

    // Outer background frame
    const bgHex = document.createElementNS(SVG_NS, "polygon");
    bgHex.setAttribute(
      "points",
      [V0, V1, V2, V3, V4, V5].map((v) => `${v.x.toFixed(1)},${v.y.toFixed(1)}`).join(" ")
    );
    bgHex.setAttribute("fill", "#e2e8f0");
    bgHex.setAttribute("stroke", "#0f172a");
    bgHex.setAttribute("stroke-width", "3");
    boardSvg.appendChild(bgHex);

    const legalMap = new Map();
    if (selectedCell !== null) {
      for (const mv of legalTargetsForCell(selectedCell)) {
        legalMap.set(mv.to, mv);
      }
    }

    // Draw all 96 cells
    for (const geom of CELL_GEOM) {
      const poly = document.createElementNS(SVG_NS, "polygon");
      poly.setAttribute("points", geom.points);
      poly.setAttribute("class", "board-cell");

      let fill = geom.parity === 1 ? "#f6efe2" : "#bfa37e";
      if (selectedCell === geom.cell) {
        fill = "#fde68a";
      }
      poly.setAttribute("fill", fill);
      poly.setAttribute("stroke", "#7c6244");
      poly.setAttribute("stroke-width", "1.1");
      poly.addEventListener("click", () => onCellClick(geom.cell));
      boardSvg.appendChild(poly);
    }

    // Draw prominent sector frontier lines meeting at center rosette C
    const frontierSegments = [
      [M_WR, C, "#dc2626"],
      [M_BW, C, "#0f172a"],
      [M_RB, C, "#475569"]
    ];
    for (const [p1, p2, col] of frontierSegments) {
      const line = document.createElementNS(SVG_NS, "line");
      line.setAttribute("x1", p1.x);
      line.setAttribute("y1", p1.y);
      line.setAttribute("x2", p2.x);
      line.setAttribute("y2", p2.y);
      line.setAttribute("stroke", col);
      line.setAttribute("stroke-width", "2.4");
      line.setAttribute("pointer-events", "none");
      boardSvg.appendChild(line);
    }

    // Highlight legal target squares
    for (const [targetCell] of legalMap.entries()) {
      const tg = CELL_GEOM[targetCell];
      const occupant = gameState.board[targetCell];
      const marker = document.createElementNS(SVG_NS, "circle");
      marker.setAttribute("cx", tg.cx);
      marker.setAttribute("cy", tg.cy);
      if (occupant) {
        marker.setAttribute("r", "16");
        marker.setAttribute("fill", "none");
        marker.setAttribute("stroke", "#dc2626");
        marker.setAttribute("stroke-width", "3.2");
      } else {
        marker.setAttribute("r", "7");
        marker.setAttribute("fill", "#1d4ed8");
        marker.setAttribute("fill-opacity", "0.75");
      }
      marker.setAttribute("pointer-events", "none");
      boardSvg.appendChild(marker);
    }

    // Draw pieces
    if (gameState && gameState.board) {
      for (let cell = 0; cell < 96; cell++) {
        const piece = gameState.board[cell];
        if (!piece) continue;
        const g = CELL_GEOM[cell];
        boardSvg.appendChild(createPieceSvg(piece.owner, piece.type, g.cx, g.cy));
      }
    }

    const sectorOutward = [
      { text: "WHITE SECTOR (a1 - h1)", base: B_W, nx: 0, ny: 1, rot: 0, color: "#0f172a" },
      { text: "RED SECTOR (a1 - h1)", base: B_R, nx: -Math.sqrt(3) / 2, ny: -0.5, rot: -60, color: "#b91c1c" },
      { text: "BLACK SECTOR (a1 - h1)", base: B_B, nx: Math.sqrt(3) / 2, ny: -0.5, rot: 60, color: "#0f172a" }
    ];

      // Draw sector labels parallel and cleanly outside the three back edges
      for (const lbl of sectorOutward) {
        const lx = lbl.base.x + lbl.nx * 38;
        const ly = lbl.base.y + lbl.ny * 38;
        const t = document.createElementNS(SVG_NS, "text");
        t.setAttribute("x", lx.toFixed(2));
        t.setAttribute("y", ly.toFixed(2));
        t.setAttribute("text-anchor", "middle");
        t.setAttribute("dominant-baseline", "middle");
        t.setAttribute("font-size", "13");
        t.setAttribute("font-weight", "700");
        t.setAttribute("fill", lbl.color);
        if (lbl.rot !== 0) {
          t.setAttribute("transform", `rotate(${lbl.rot}, ${lx.toFixed(2)}, ${ly.toFixed(2)})`);
        }
        t.textContent = lbl.text;
        boardSvg.appendChild(t);
      }

      // Draw file letters (a..h) cleanly outside each sector's rank-0 outer edge
      for (let s = 0; s < 3; s++) {
        const meta = sectorOutward[s];
        for (let f = 0; f < 8; f++) {
          const cell = s * 32 + f;
          const g = CELL_GEOM[cell];
          const lx = g.outerMid.x + meta.nx * 16;
          const ly = g.outerMid.y + meta.ny * 16;
          const txt = document.createElementNS(SVG_NS, "text");
          txt.setAttribute("x", lx.toFixed(2));
          txt.setAttribute("y", ly.toFixed(2));
          txt.setAttribute("text-anchor", "middle");
          txt.setAttribute("dominant-baseline", "middle");
          txt.setAttribute("font-size", "11");
          txt.setAttribute("font-weight", "600");
          txt.setAttribute("fill", "#475569");
          txt.textContent = FILES[f];
          boardSvg.appendChild(txt);
        }
      }
    }

    function renderTelemetry() {
      if (!gameState) return;

      const aliveCount = gameState.alive_count;
      phaseBadge.textContent =
        aliveCount === 3
          ? "Phase 1: 3-Player Tri-Sector"
          : aliveCount === 2
            ? "Phase 2: 2-Player Endgame"
            : "Match Concluded";

      plyBadge.textContent = `Ply ${gameState.ply}`;

      turnBadge.className = "badge badge-turn";
      if (gameState.is_game_over) {
        turnBadge.textContent =
          gameState.winner !== null && gameState.winner !== undefined
            ? `Winner: ${PLAYER_NAMES[gameState.winner]}`
            : "Result: Draw";
      } else {
        turnBadge.textContent = `Turn: ${PLAYER_NAMES[gameState.side_to_move]}`;
        if (gameState.side_to_move === 1) turnBadge.classList.add("turn-red");
        if (gameState.side_to_move === 2) turnBadge.classList.add("turn-black");
      }

      if (gameState.last_eliminated_player !== null && gameState.last_eliminated_player !== undefined) {
        const elimName = PLAYER_NAMES[gameState.last_eliminated_player];
        elimBanner.classList.remove("hidden");
        elimText.textContent = `Sudden Disappearance Triggered: ${elimName} was checkmated and ${gameState.last_eliminated_piece_count} remaining pieces were immediately removed from the 96-cell board.`;
      } else if (!gameState.is_game_over && aliveCount === 3) {
        elimBanner.classList.add("hidden");
      }

      for (let p = 0; p < 3; p++) {
        const card = document.getElementById(`card-player-${p}`);
        const status = document.getElementById(`status-${p}`);
        const alive = (gameState.alive_mask & (1 << p)) !== 0;
        const inChk = gameState.in_check[p];

        card.classList.remove("active-turn", "eliminated");
        status.className = "pill";
        if (!alive) {
          card.classList.add("eliminated");
          status.classList.add("pill-out");
          status.textContent = "Eliminated";
        } else if (inChk) {
          status.classList.add("pill-check");
          status.textContent = "In Check";
        } else {
          status.classList.add("pill-alive");
          status.textContent = gameState.side_to_move === p && !gameState.is_game_over ? "Active" : "Alive";
        }

        if (alive && gameState.side_to_move === p && !gameState.is_game_over) {
          card.classList.add("active-turn");
        }

        document.getElementById(`count-${p}`).textContent = gameState.piece_counts[p];
        document.getElementById(`eval-${p}`).textContent = gameState.eval_scores[p];
        document.getElementById(`hex-${p}`).textContent = gameState.occ_hex[p];
      }

      if (gameState.elimination_log && gameState.elimination_log.length > 0) {
        elimLog.classList.remove("empty-state");
        elimLog.innerHTML = gameState.elimination_log
          .map(
            (ev) =>
              `<div class="log-item">Ply ${ev.ply}: <strong>${ev.eliminated_name}</strong> eliminated by <strong>${ev.by_name}</strong> (${ev.reason}, ${ev.pieces_removed} pieces vanished, ${ev.surviving_count} surviving)</div>`
          )
          .join("");
      } else {
        elimLog.classList.add("empty-state");
        elimLog.textContent =
          "No armies eliminated yet. Checkmate removes all remaining pieces of the mated player immediately.";
      }

      const hist = [...(gameState.move_history || [])].reverse();
      moveHistoryEl.innerHTML = hist
        .map((m) => `<li><strong>${m.player_name}:</strong> <span class="mono">${m.notation}</span></li>`)
        .join("");
      moveHistoryEl.scrollTop = moveHistoryEl.scrollHeight;

      if (gameState.ai_telemetry) {
        const t = gameState.ai_telemetry;
        telemetryLine.textContent = `${t.phase} | depth ${t.depth} | ${t.nodes} nodes in ${t.time_ms} ms | score ${t.score}`;
      } else {
        telemetryLine.textContent = `${gameState.legal_moves ? gameState.legal_moves.length : 0} legal moves available`;
      }
    }

    function applyStateUpdate(nextState) {
      gameState = nextState;
      selectedCell = null;
      renderBoard();
      renderTelemetry();
    }

    function isCurrentPlayerAI() {
      if (!gameState || gameState.is_game_over) return false;
      const sel = document.querySelector(`.controller-select[data-player="${gameState.side_to_move}"]`);
      return sel && sel.value === "ai";
    }

    async function onCellClick(cell) {
      if (busy || !gameState || gameState.is_game_over) return;

      if (selectedCell !== null) {
        const targets = legalTargetsForCell(selectedCell);
        const match = targets.find((m) => m.to === cell);
        if (match) {
          const promo = match.promo !== 0 ? parseInt(document.getElementById("promo-piece").value, 10) : 0;
          busy = true;
          try {
            const res = await apiPost("/api/move", { from: selectedCell, to: cell, promo });
            if (res.ok && res.state) {
              applyStateUpdate(res.state);
              selectionHint.textContent = "Move executed.";
              maybeScheduleAI();
            } else {
              selectionHint.textContent = res.error || "Illegal move.";
            }
          } finally {
            busy = false;
          }
          return;
        }
      }

      const piece = gameState.board[cell];
      if (piece && piece.owner === gameState.side_to_move) {
        selectedCell = cell;
        const targets = legalTargetsForCell(cell);
        selectionHint.textContent = `Selected ${PLAYER_NAMES[piece.owner]} ${PIECE_NAMES[piece.type]} (${targets.length} legal targets).`;
        renderBoard();
      } else {
        selectedCell = null;
        selectionHint.textContent = `Select a piece belonging to ${PLAYER_NAMES[gameState.side_to_move]}.`;
        renderBoard();
      }
    }

    async function stepAI() {
      if (busy || !gameState || gameState.is_game_over) return false;
      busy = true;
      try {
        const strategy = document.getElementById("ai-strategy").value;
        const depth = parseInt(document.getElementById("ai-depth").value, 10);
        const res = await apiPost("/api/ai_move", { strategy, depth });
        if (res.ok && res.state) {
          applyStateUpdate(res.state);
          return !res.state.is_game_over;
        }
        return false;
      } finally {
        busy = false;
      }
    }

    function maybeScheduleAI() {
      if (autoPlayTimer) return;
      if (isCurrentPlayerAI()) {
        setTimeout(async () => {
          if (!autoPlayTimer && isCurrentPlayerAI()) {
            const cont = await stepAI();
            if (cont) maybeScheduleAI();
          }
        }, 220);
      }
    }

    function stopAutoPlay() {
      if (autoPlayTimer) {
        clearInterval(autoPlayTimer);
        autoPlayTimer = null;
      }
      btnAutoPlay.classList.remove("btn-active");
      btnAutoPlay.textContent = "Auto-Play AI";
    }

    document.getElementById("btn-new").addEventListener("click", async () => {
      stopAutoPlay();
      const st = await apiPost("/api/reset");
      applyStateUpdate(st);
      selectionHint.textContent = "Standard 48-piece 96-cell board initialized.";
    });

    document.getElementById("btn-demo").addEventListener("click", async () => {
      stopAutoPlay();
      const st = await apiPost("/api/demo");
      applyStateUpdate(st);
      selectionHint.textContent =
        "Elimination Demo loaded: Move White Queen from R:f3 to R:g2 (or click Step AI Move) to checkmate Red and observe all Red pieces disappear.";
    });

    document.getElementById("btn-ai-step").addEventListener("click", async () => {
      stopAutoPlay();
      await stepAI();
    });

    btnAutoPlay.addEventListener("click", () => {
      if (autoPlayTimer) {
        stopAutoPlay();
        return;
      }
      btnAutoPlay.classList.add("btn-active");
      btnAutoPlay.textContent = "Pause Auto-Play";
      autoPlayTimer = setInterval(async () => {
        if (gameState && gameState.is_game_over) {
          stopAutoPlay();
          return;
        }
        if (!busy) {
          await stepAI();
        }
      }, 350);
    });

    function buildOfflinePreviewState() {
      const board = new Array(96).fill(null);
      const backRank = [3, 1, 2, 4, 5, 2, 1, 3];
      for (let s = 0; s < 3; s++) {
        for (let f = 0; f < 8; f++) {
          board[s * 32 + f] = { owner: s, type: backRank[f] };
          board[s * 32 + 8 + f] = { owner: s, type: 0 };
        }
      }
      return {
        board,
        side_to_move: 0,
        alive_mask: 7,
        alive_count: 3,
        ply: 0,
        is_game_over: false,
        winner: null,
        in_check: [false, false, false],
        last_eliminated_player: null,
        last_eliminated_piece_count: 0,
        legal_moves: [],
        occ_hex: [
          "0x00000000_00000000_0000FFFF",
          "0x00000000_0000FFFF_00000000",
          "0x0000FFFF_00000000_00000000"
        ],
        piece_counts: [16, 16, 16],
        eval_scores: [0, 0, 0],
        move_history: [],
        elimination_log: [],
        ai_telemetry: null
      };
    }

    (async function init() {
      try {
        const st = await apiGet("/api/state");
        applyStateUpdate(st);
      } catch (_err) {
        applyStateUpdate(buildOfflinePreviewState());
        telemetryLine.textContent = "Server disconnected - run mix three_chess.serve";
        selectionHint.textContent =
          "Rendering static board preview. Start the Elixir/OTP server with mix three_chess.serve to play.";
      }
    })();
  }) ();
