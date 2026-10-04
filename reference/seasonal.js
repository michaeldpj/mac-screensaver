(() => {
  'use strict';

  if (typeof window === 'undefined' || !window.matchMedia) return;
  if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;

  const VALID = ['snow', 'petals', 'fireflies', 'leaves', 'off'];
  const SEASON_TO_EFFECT = { winter: 'snow', spring: 'petals', summer: 'fireflies', autumn: 'leaves' };
  const params = new URLSearchParams(window.location.search);
  const override = params.get('effect');
  const dataSeason = document.documentElement.getAttribute('data-season');
  const effect = VALID.includes(override)
    ? override
    : (SEASON_TO_EFFECT[dataSeason] || seasonByMonth(new Date().getMonth()));
  if (effect === 'off') return;

  const isMobile = window.matchMedia('(max-width: 640px)').matches;

  const MAPLE = new Path2D('M 0,-1 L 0.18,-0.45 L 0.7,-0.55 L 0.45,-0.05 L 0.95,0.15 L 0.55,0.35 L 0.7,0.85 L 0.2,0.55 L 0.05,1 L -0.05,1 L -0.2,0.55 L -0.7,0.85 L -0.55,0.35 L -0.95,0.15 L -0.45,-0.05 L -0.7,-0.55 L -0.18,-0.45 Z');
  const OAK = new Path2D('M 0,-1 C 0.35,-0.85 0.55,-0.55 0.45,-0.25 C 0.85,-0.15 0.85,0.2 0.4,0.3 C 0.7,0.55 0.45,0.9 0.1,0.75 L 0,1 L -0.1,0.75 C -0.45,0.9 -0.7,0.55 -0.4,0.3 C -0.85,0.2 -0.85,-0.15 -0.45,-0.25 C -0.55,-0.55 -0.35,-0.85 0,-1 Z');

  const CONFIGS = {
    snow: {
      count: isMobile ? 16 : 30,
      color: 'oklch(95% 0 0 / 0.75)',
      sizeMin: 10, sizeMax: 22,
      vyMin: 18, vyMax: 45,
      swayAmp: 14, swayPeriod: [6, 10],
      rotate: true, rotateSpeed: 0.25, glow: false, pulse: false,
      tumble: false,
      spriteOpacity: 0.55,
      glyphType: 'image',
      sprites: [1, 2, 3, 4].map(n => `/images/seasonal/snow/${n}.webp`),
      fallback: { type: 'text', glyphs: ['❄︎', '❅︎', '❆︎'] }
    },
    petals: {
      count: isMobile ? 12 : 22,
      color: 'oklch(92% 0.06 25 / 0.6)',
      sizeMin: 12, sizeMax: 26,
      vyMin: 10, vyMax: 25,
      swayAmp: 28, swayPeriod: [5, 9],
      rotate: true, rotateSpeed: 0.4, glow: false, pulse: false,
      tumble: true, tumbleSpeed: 0.6,
      spriteOpacity: 0.6,
      glyphType: 'image',
      sprites: [1, 2, 3, 4, 5, 6].map(n => `/images/seasonal/petals/${n}.webp`),
      fallback: { type: 'text', glyphs: ['❀︎', '✿︎', '❁︎'] }
    },
    fireflies: {
      count: isMobile ? 12 : 25,
      color: 'oklch(88% 0.16 95 / 0.65)',
      sizeMin: 1.4, sizeMax: 2.6,
      vyMin: -15, vyMax: 15,
      swayAmp: 18, swayPeriod: [3, 6],
      rotate: false, glow: true, pulse: true,
      tumble: false,
      glyphType: 'glow'
    },
    leaves: {
      count: isMobile ? 12 : 22,
      color: 'oklch(72% 0.14 50 / 0.7)',
      sizeMin: 12, sizeMax: 26,
      vyMin: 25, vyMax: 55,
      swayAmp: 32, swayPeriod: [4, 8],
      rotate: true, rotateSpeed: 0.7, glow: false, pulse: false,
      tumble: true, tumbleSpeed: 0.9,
      spriteOpacity: 0.6,
      glyphType: 'image',
      sprites: [1, 2, 3, 4, 5].map(n => `/images/seasonal/leaves/${n}.webp`),
      fallback: { type: 'path', paths: [MAPLE, OAK] }
    }
  };

  const cfg = CONFIGS[effect];
  if (!cfg) return;

  const canvas = document.createElement('canvas');
  canvas.className = 'season-canvas';
  canvas.setAttribute('aria-hidden', 'true');
  document.body.appendChild(canvas);
  const ctx = canvas.getContext('2d', { alpha: true });
  if (!ctx) return;

  const dpr = Math.min(window.devicePixelRatio || 1, 2);
  let w = 0, h = 0;
  const particles = [];
  let images = null;
  let activeType = cfg.glyphType;
  let activeVariants = [];

  function rand(a, b) { return a + Math.random() * (b - a); }

  function spawn(p, fromTop) {
    p.x = rand(0, w);
    p.y = fromTop ? rand(-h * 0.5, 0) : rand(0, h);
    p.r = rand(cfg.sizeMin, cfg.sizeMax);
    p.vy = rand(cfg.vyMin, cfg.vyMax);
    p.vx = effect === 'fireflies' ? rand(-15, 15) : 0;
    p.phase = rand(0, Math.PI * 2);
    p.freq = (Math.PI * 2) / rand(cfg.swayPeriod[0], cfg.swayPeriod[1]);
    p.rot = cfg.rotate ? rand(0, Math.PI * 2) : 0;
    p.vrot = cfg.rotate ? rand(-cfg.rotateSpeed, cfg.rotateSpeed) : 0;
    p.tumble = cfg.tumble ? rand(0, Math.PI * 2) : 0;
    p.vtumble = cfg.tumble ? rand(-cfg.tumbleSpeed, cfg.tumbleSpeed) : 0;
    p.pulsePhase = cfg.pulse ? rand(0, Math.PI * 2) : 0;
    p.pulseFreq = cfg.pulse ? (Math.PI * 2) / rand(2, 4) : 0;
    p.depth = rand(0.6, 1);
    p.alphaJitter = rand(0.7, 1);
    p.variant = Math.floor(Math.random() * Math.max(activeVariants.length, 1));
  }

  function resize() {
    w = window.innerWidth;
    h = window.innerHeight;
    canvas.width = Math.round(w * dpr);
    canvas.height = Math.round(h * dpr);
    canvas.style.width = w + 'px';
    canvas.style.height = h + 'px';
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  }

  function edgeFade(p) {
    const top = Math.min(1, Math.max(0, (p.y + 60) / 60));
    const bot = Math.min(1, Math.max(0, (h - p.y) / 80));
    return Math.min(top, bot);
  }

  function draw(p, alpha) {
    const fade = edgeFade(p);
    const a = alpha * p.alphaJitter * fade;
    ctx.globalAlpha = a;

    if (activeType === 'image') {
      const img = activeVariants[p.variant];
      const size = p.r * p.depth * 2;
      ctx.save();
      ctx.translate(p.x, p.y);
      ctx.rotate(p.rot);
      if (cfg.tumble) ctx.scale(1, Math.cos(p.tumble));
      ctx.globalAlpha = a * cfg.spriteOpacity;
      ctx.drawImage(img, -size / 2, -size / 2, size, size);
      ctx.restore();
    } else if (activeType === 'text') {
      ctx.fillStyle = cfg.color;
      const size = p.r * p.depth * 2;
      ctx.save();
      ctx.translate(p.x, p.y);
      ctx.rotate(p.rot);
      ctx.font = `${size}px -apple-system, "Segoe UI Symbol", "Apple Symbols", sans-serif`;
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.fillText(activeVariants[p.variant], 0, 0);
      ctx.restore();
    } else if (activeType === 'path') {
      ctx.fillStyle = cfg.color;
      const s = p.r * p.depth;
      ctx.save();
      ctx.translate(p.x, p.y);
      ctx.rotate(p.rot);
      ctx.scale(s, s);
      ctx.fill(activeVariants[p.variant]);
      ctx.restore();
    } else {
      ctx.fillStyle = cfg.color;
      ctx.beginPath();
      ctx.arc(p.x, p.y, p.r * p.depth, 0, Math.PI * 2);
      ctx.fill();
    }
  }

  let last = performance.now();
  let running = true;
  let raf = 0;

  function frame(now) {
    raf = 0;
    if (!running) return;
    const dt = Math.min((now - last) / 1000, 0.05);
    last = now;

    ctx.clearRect(0, 0, w, h);
    if (cfg.glow) {
      ctx.shadowBlur = 10;
      ctx.shadowColor = cfg.color;
    } else {
      ctx.shadowBlur = 0;
    }

    for (const p of particles) {
      p.phase += p.freq * dt;
      p.y += p.vy * p.depth * dt;
      const swayX = Math.sin(p.phase) * cfg.swayAmp * p.depth;
      p.x += (p.vx * p.depth * dt) + (swayX * dt * 0.4);
      if (cfg.rotate) p.rot += p.vrot * dt;
      if (cfg.tumble) p.tumble += p.vtumble * dt;

      let alpha = 1;
      if (cfg.pulse) {
        p.pulsePhase += p.pulseFreq * dt;
        alpha = 0.3 + 0.5 * (0.5 + 0.5 * Math.sin(p.pulsePhase));
      }

      const margin = p.r * 2;
      if (p.y - margin > h || p.x < -margin - 50 || p.x > w + margin + 50) {
        spawn(p, true);
        continue;
      }

      draw(p, alpha);
    }
    ctx.globalAlpha = 1;
    raf = requestAnimationFrame(frame);
  }

  let started = false;

  function startEngine() {
    if (started) return;
    started = true;
    resize();
    for (let i = 0; i < cfg.count; i++) {
      const p = {};
      spawn(p, false);
      particles.push(p);
    }
    raf = requestAnimationFrame((t) => { last = t; frame(t); });

    document.addEventListener('visibilitychange', () => {
      if (document.hidden) {
        running = false;
        if (raf) cancelAnimationFrame(raf);
        raf = 0;
      } else if (!running) {
        running = true;
        last = performance.now();
        raf = requestAnimationFrame(frame);
      }
    });

    if (typeof ResizeObserver !== 'undefined') {
      const ro = new ResizeObserver(() => resize());
      ro.observe(document.documentElement);
    } else {
      window.addEventListener('resize', resize);
    }
  }

  function useFallback() {
    if (cfg.fallback) {
      activeType = cfg.fallback.type;
      activeVariants = cfg.fallback.glyphs || cfg.fallback.paths || [];
    } else {
      activeType = cfg.glyphType;
      activeVariants = [];
    }
    startEngine();
  }

  if (cfg.glyphType === 'image') {
    images = cfg.sprites.map(src => {
      const img = new Image();
      img.decoding = 'async';
      img.src = src;
      return img;
    });
    let pending = images.length;
    let failed = 0;
    images.forEach(img => {
      const done = (ok) => {
        if (!ok) failed++;
        pending--;
        if (pending === 0) {
          if (failed === images.length) {
            useFallback();
          } else {
            const ok = images.filter(i => i.complete && i.naturalWidth > 0);
            if (ok.length === 0) {
              useFallback();
              return;
            }
            activeType = 'image';
            activeVariants = ok;
            startEngine();
          }
        }
      };
      if (img.complete) {
        done(img.naturalWidth > 0);
      } else {
        img.addEventListener('load', () => done(true), { once: true });
        img.addEventListener('error', () => done(false), { once: true });
      }
    });
  } else if (cfg.glyphType === 'glow') {
    activeType = 'glow';
    activeVariants = [];
    startEngine();
  } else if (cfg.glyphType === 'text') {
    activeType = 'text';
    activeVariants = cfg.glyphs;
    startEngine();
  } else if (cfg.glyphType === 'path') {
    activeType = 'path';
    activeVariants = cfg.paths;
    startEngine();
  }

  function seasonByMonth(m) {
    if (m === 11 || m === 0 || m === 1) return 'snow';
    if (m >= 2 && m <= 4) return 'petals';
    if (m >= 5 && m <= 7) return 'fireflies';
    return 'leaves';
  }
})();
