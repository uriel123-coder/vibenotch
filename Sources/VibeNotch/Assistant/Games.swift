import Foundation

/// «hazme un juego de gatos que atrapan peces»: one of four tested game engines, dressed up for what you asked.
/// The on-device model can't write a whole game without bugs, but it picks and themes one well.
enum Games {
    struct Config {
        var mode = "serpiente"
        var title = "Minijuego"
        var player = ""
        var target = ""
        var color = "#34d399"
        var speed = 2.0
    }

    static let modes = ["serpiente", "pong", "bloques", "naves"]

    /// Without the model: the kind of game from its usual words.
    static func guess(_ ask: String) -> Config {
        let f = ask.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        var c = Config()
        let words: [(String, [String])] = [
            ("pong", ["pong", "tenis", "ping", "raqueta", "pelota contra"]),
            ("bloques", ["bloques", "ladrillos", "breakout", "arkanoid", "romper"]),
            ("naves", ["naves", "nave", "disparar", "dispara", "espacio", "aliens", "marcianos", "asteroides", "invaders", "shooter"]),
            ("serpiente", ["serpiente", "snake", "viborita", "vibora", "gusano", "comer"]),
        ]
        c.mode = words.first { $0.1.contains { f.contains($0) } }?.0 ?? "serpiente"
        c.title = ["serpiente": "La Serpiente", "pong": "Pong", "bloques": "Rompe Bloques", "naves": "Guerra Espacial"][c.mode] ?? "Minijuego"
        return c
    }

    static func html(_ c: Config) -> String {
        let mode = modes.contains(c.mode) ? c.mode : "serpiente"
        let color = c.color.range(of: #"^#[0-9a-fA-F]{6}$"#, options: .regularExpression) != nil ? c.color : "#34d399"
        let config: [String: Any] = ["mode": mode, "title": String(c.title.prefix(40)), "player": String(c.player.prefix(4)),
                                     "target": String(c.target.prefix(4)), "color": color, "speed": min(3, max(1, c.speed))]
        let json = (try? JSONSerialization.data(withJSONObject: config)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let title = c.title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        return template.replacingOccurrences(of: "{{TITLE}}", with: title)
            .replacingOccurrences(of: "{{CONFIG}}", with: json.replacingOccurrences(of: "</", with: "<\\/"))
    }

    private static let template = """
    <!DOCTYPE html>
    <html lang="es"><head><meta charset="utf-8"><title>{{TITLE}}</title>
    <style>
    html,body{margin:0;height:100%;background:#0b0b12;color:#fff;font-family:-apple-system,Helvetica,sans-serif}
    body{display:flex;flex-direction:column;align-items:center;justify-content:center;gap:12px}
    canvas{border-radius:16px;box-shadow:0 20px 60px #000a;max-width:96vw}
    p{opacity:.6;font-size:14px;margin:0}
    </style></head>
    <body><canvas id="c" width="640" height="480"></canvas><p id="help"></p>
    <script>
    const CFG = {{CONFIG}};
    const c = document.getElementById('c'), x = c.getContext('2d'), W = c.width, H = c.height, sp = CFG.speed;
    const keys = {}; let mouseX = null, mouseY = null, mouseDown = false, score = 0, over = false, S = {};
    const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
    addEventListener('keydown', e => {
      keys[e.key] = true;
      if (e.key === ' ' || e.key.startsWith('Arrow')) e.preventDefault();
      if (e.key === 'r' || e.key === 'R') return reset();
      if (!over && M.key) M.key(e.key);
    });
    addEventListener('keyup', e => { keys[e.key] = false; });
    c.addEventListener('mousemove', e => { const r = c.getBoundingClientRect(); mouseX = (e.clientX - r.left) * W / r.width; mouseY = (e.clientY - r.top) * H / r.height; });
    c.addEventListener('mousedown', () => { mouseDown = true; });
    addEventListener('mouseup', () => { mouseDown = false; });
    function emoji(ch, px, py, size) { x.font = size + 'px "Apple Color Emoji",serif'; x.textAlign = 'center'; x.textBaseline = 'middle'; x.fillText(ch, px, py); }
    function ball(px, py) { if (CFG.target) return emoji(CFG.target, px, py, 20); x.fillStyle = '#fff'; x.beginPath(); x.arc(px, py, 8, 0, 7); x.fill(); }
    function steer(v, speed, dt) {
      if (keys.ArrowLeft || keys.a || keys.ArrowUp || keys.w) return v - speed * dt;
      if (keys.ArrowRight || keys.d || keys.ArrowDown || keys.s) return v + speed * dt;
      return null;
    }

    const modes = {
      serpiente: {
        help: 'Flechas para moverte · R para reiniciar',
        G: 20,
        init() { S = { b: [{ x: 8, y: 12 }, { x: 7, y: 12 }, { x: 6, y: 12 }], d: { x: 1, y: 0 }, n: { x: 1, y: 0 }, acc: 0 }; S.f = this.spot(); },
        spot() {
          const cw = W / this.G, ch = H / this.G; let p;
          do { p = { x: Math.floor(Math.random() * cw), y: Math.floor(Math.random() * ch) }; } while (S.b.some(q => q.x === p.x && q.y === p.y));
          return p;
        },
        key(k) {
          const m = { ArrowUp: [0, -1], ArrowDown: [0, 1], ArrowLeft: [-1, 0], ArrowRight: [1, 0], w: [0, -1], s: [0, 1], a: [-1, 0], d: [1, 0] }[k];
          if (m && (m[0] !== -S.d.x || m[1] !== -S.d.y)) S.n = { x: m[0], y: m[1] };
        },
        update(dt) {
          S.acc += dt; const step = 150 / sp, cw = W / this.G, ch = H / this.G;
          while (S.acc >= step && !over) {
            S.acc -= step; S.d = S.n;
            const h = { x: S.b[0].x + S.d.x, y: S.b[0].y + S.d.y };
            if (h.x < 0 || h.y < 0 || h.x >= cw || h.y >= ch || S.b.some(p => p.x === h.x && p.y === h.y)) { over = true; return; }
            S.b.unshift(h);
            if (h.x === S.f.x && h.y === S.f.y) { score++; S.f = this.spot(); } else S.b.pop();
          }
        },
        draw() {
          const G = this.G;
          S.b.forEach((p, i) => {
            if (i === 0 && CFG.player) return emoji(CFG.player, p.x * G + G / 2, p.y * G + G / 2, G + 2);
            x.globalAlpha = Math.max(0.35, 1 - i / (S.b.length * 1.4)); x.fillStyle = CFG.color;
            x.fillRect(p.x * G + 1, p.y * G + 1, G - 2, G - 2);
          });
          x.globalAlpha = 1;
          emoji(CFG.target || '🍎', S.f.x * G + G / 2, S.f.y * G + G / 2, G);
        }
      },

      pong: {
        help: 'Flechas o el ratón para mover tu raqueta · R para reiniciar',
        PH: 90,
        init() { S = { py: H / 2, cy: H / 2, lives: 3 }; this.serve(); },
        serve() { S.bx = W / 2; S.by = H / 2; S.vx = 300 * sp * (Math.random() < 0.5 ? 1 : -1); S.vy = (Math.random() * 2 - 1) * 180; },
        update(dt) {
          const s = dt / 1000, PH = this.PH;
          const moved = steer(S.py, 480, s);
          S.py = clamp(moved ?? (mouseY ?? S.py), PH / 2, H - PH / 2);
          S.cy = clamp(S.cy + clamp(S.by - S.cy, -240 * sp * s, 240 * sp * s), PH / 2, H - PH / 2);
          S.bx += S.vx * s; S.by += S.vy * s;
          if (S.by < 8 || S.by > H - 8) { S.vy *= -1; S.by = clamp(S.by, 8, H - 8); }
          if (S.vx < 0 && S.bx < 38 && S.bx > 14 && Math.abs(S.by - S.py) < PH / 2 + 8) { S.vx = Math.min(Math.abs(S.vx) * 1.05, 520 + 120 * sp); S.vy = clamp(S.vy + (S.by - S.py) * 4, -520 * sp, 520 * sp); }
          if (S.vx > 0 && S.bx > W - 38 && S.bx < W - 14 && Math.abs(S.by - S.cy) < PH / 2 + 8) { S.vx = -Math.min(Math.abs(S.vx) * 1.05, 520 + 120 * sp); S.vy = clamp(S.vy + (S.by - S.cy) * 4, -520 * sp, 520 * sp); }
          if (S.bx < -10) { S.lives--; if (S.lives <= 0) over = true; else this.serve(); }
          if (S.bx > W + 10) { score++; this.serve(); }
        },
        draw() {
          x.fillStyle = '#ffffff22'; for (let y = 10; y < H; y += 30) x.fillRect(W / 2 - 2, y, 4, 16);
          x.fillStyle = CFG.color; x.fillRect(18, S.py - this.PH / 2, 12, this.PH);
          x.fillStyle = '#f87171'; x.fillRect(W - 30, S.cy - this.PH / 2, 12, this.PH);
          ball(S.bx, S.by);
        }
      },

      bloques: {
        help: 'Flechas o el ratón para mover · Espacio o clic para lanzar · R para reiniciar',
        init() { S = { px: W / 2, lives: 3, level: 1 }; this.bricks(); this.ready(); },
        bricks() {
          S.br = []; const cols = 8, w = (W - 40) / cols;
          for (let r = 0; r < 5; r++) for (let i = 0; i < cols; i++) S.br.push({ x: 20 + i * w + 3, y: 50 + r * 26, w: w - 6, h: 18, r, on: true });
        },
        ready() { S.stuck = true; S.bx = S.px; S.by = H - 42; S.vx = 160; S.vy = -(320 + S.level * 30) * sp / 2; },
        update(dt) {
          const s = dt / 1000;
          const moved = steer(S.px, 560, s);
          S.px = clamp(moved ?? (mouseX ?? S.px), 50, W - 50);
          if (S.stuck) { S.bx = S.px; S.by = H - 42; if (keys[' '] || mouseDown) S.stuck = false; return; }
          S.bx += S.vx * s; S.by += S.vy * s;
          if (S.bx < 8 || S.bx > W - 8) { S.vx *= -1; S.bx = clamp(S.bx, 8, W - 8); }
          if (S.by < 8) S.vy = Math.abs(S.vy);
          if (S.vy > 0 && S.by > H - 40 && S.by < H - 20 && Math.abs(S.bx - S.px) < 58) { S.vy = -Math.abs(S.vy); S.vx = (S.bx - S.px) * 7; }
          for (const b of S.br) {
            if (b.on && S.bx > b.x - 6 && S.bx < b.x + b.w + 6 && S.by > b.y - 6 && S.by < b.y + b.h + 6) { b.on = false; S.vy *= -1; score++; break; }
          }
          if (S.br.every(b => !b.on)) { S.level++; this.bricks(); this.ready(); }
          if (S.by > H + 10) { S.lives--; if (S.lives <= 0) over = true; else this.ready(); }
        },
        draw() {
          for (const b of S.br) if (b.on) { x.fillStyle = `hsl(${(b.r * 40 + 180) % 360},80%,60%)`; x.fillRect(b.x, b.y, b.w, b.h); }
          x.fillStyle = CFG.color; x.fillRect(S.px - 50, H - 30, 100, 12);
          ball(S.bx, S.by);
        }
      },

      naves: {
        help: 'Flechas o el ratón para moverte · Espacio o clic para disparar · R para reiniciar',
        init() { S = { px: W / 2, shots: [], foes: [], lives: 3, cool: 0, spawn: 0 }; },
        update(dt) {
          const s = dt / 1000;
          const moved = steer(S.px, 480, s);
          S.px = clamp(moved ?? (mouseX ?? S.px), 24, W - 24);
          S.cool -= dt;
          if ((keys[' '] || mouseDown) && S.cool <= 0) { S.shots.push({ x: S.px, y: H - 60 }); S.cool = 240; }
          S.spawn -= dt;
          if (S.spawn <= 0) { S.foes.push({ x: 24 + Math.random() * (W - 48), y: -20, v: (70 + Math.random() * 60 + score * 3) * sp }); S.spawn = Math.max(260, 900 - score * 15) / sp; }
          S.shots.forEach(p => { p.y -= 620 * s; });
          S.foes.forEach(f => { f.y += f.v * s; });
          for (const f of S.foes) for (const p of S.shots) if (!f.dead && !p.dead && Math.abs(f.x - p.x) < 22 && Math.abs(f.y - p.y) < 22) { f.dead = p.dead = true; score++; }
          for (const f of S.foes) if (!f.dead && (f.y > H + 10 || (Math.abs(f.x - S.px) < 28 && Math.abs(f.y - (H - 40)) < 28))) { f.dead = true; S.lives--; if (S.lives <= 0) over = true; }
          S.foes = S.foes.filter(f => !f.dead); S.shots = S.shots.filter(p => !p.dead && p.y > -20);
        },
        draw() {
          x.fillStyle = CFG.color; S.shots.forEach(p => x.fillRect(p.x - 2, p.y - 10, 4, 14));
          S.foes.forEach(f => emoji(CFG.target || '👾', f.x, f.y, 32));
          emoji(CFG.player || '🚀', S.px, H - 40, 38);
        }
      }
    };

    const M = modes[CFG.mode] || modes.serpiente;
    document.getElementById('help').textContent = M.help;
    function reset() { score = 0; over = false; M.init(); }
    function hud() {
      x.fillStyle = '#fff'; x.font = 'bold 18px -apple-system,sans-serif'; x.textAlign = 'left'; x.textBaseline = 'top';
      x.fillText(CFG.title + '  ·  ' + score, 14, 12);
      if (S.lives !== undefined) { x.textAlign = 'right'; x.font = '18px "Apple Color Emoji",serif'; x.fillText('❤️'.repeat(Math.max(0, S.lives)), W - 14, 12); }
    }
    function gameOver() {
      x.fillStyle = '#000b'; x.fillRect(0, 0, W, H); x.fillStyle = '#fff'; x.textAlign = 'center'; x.textBaseline = 'middle';
      x.font = 'bold 44px -apple-system,sans-serif'; x.fillText('Game Over', W / 2, H / 2 - 22);
      x.font = '20px -apple-system,sans-serif'; x.fillText('Puntos: ' + score + '  ·  R para jugar otra vez', W / 2, H / 2 + 26);
    }
    let last = performance.now();
    function loop(t) {
      const dt = Math.min(50, t - last); last = t;
      if (!over) M.update(dt);
      x.fillStyle = '#111827'; x.fillRect(0, 0, W, H);
      M.draw(); hud();
      if (over) gameOver();
      requestAnimationFrame(loop);
    }
    reset(); requestAnimationFrame(loop);
    </script></body></html>
    """
}
