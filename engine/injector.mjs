import fs from "node:fs/promises";
import path from "node:path";

function parseArgs(argv) {
  const options = {
    port: 0,
    mode: "watch",
    timeoutMs: 30000,
    idleExitMs: 30000,
    screenshot: null,
    themeRoot: null,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--port") options.port = Number(argv[++index]);
    else if (arg === "--theme-root") options.themeRoot = path.resolve(argv[++index]);
    else if (arg === "--watch") options.mode = "watch";
    else if (arg === "--once") options.mode = "once";
    else if (arg === "--verify") options.mode = "verify";
    else if (arg === "--remove") options.mode = "remove";
    else if (arg === "--timeout-ms") options.timeoutMs = Number(argv[++index]);
    else if (arg === "--idle-exit-ms") options.idleExitMs = Number(argv[++index]);
    else if (arg === "--screenshot") options.screenshot = path.resolve(argv[++index]);
    else throw new Error(`Unknown argument: ${arg}`);
  }
  if (!Number.isInteger(options.port) || options.port < 1024 || options.port > 65535) {
    throw new Error(`Invalid loopback CDP port: ${options.port}`);
  }
  if (!options.themeRoot) throw new Error("--theme-root is required");
  return options;
}

function assertInside(target, root, label) {
  const relative = path.relative(root, target);
  if (relative.startsWith("..") || path.isAbsolute(relative)) {
    throw new Error(`${label} escaped theme root: ${target}`);
  }
}

function mimeFor(filename) {
  const extension = path.extname(filename).toLowerCase();
  if (extension === ".png") return "image/png";
  if (extension === ".jpg" || extension === ".jpeg") return "image/jpeg";
  if (extension === ".webp") return "image/webp";
  throw new Error(`Unsupported hero image type: ${extension || "none"}`);
}

async function loadPayload(themeRoot) {
  const themePath = path.join(themeRoot, "theme.json");
  const cssPath = path.join(themeRoot, "noir-gold.css");
  const templatePath = path.join(themeRoot, "renderer-inject.js");
  const theme = JSON.parse(await fs.readFile(themePath, "utf8"));
  if (theme.customizationRequired === true) {
    throw new Error("Theme is still marked customizationRequired; build a customer package first.");
  }
  if (!theme.heroAsset || typeof theme.heroAsset !== "string") {
    throw new Error("theme.heroAsset is required");
  }

  const heroPath = path.resolve(themeRoot, theme.heroAsset);
  assertInside(heroPath, themeRoot, "hero asset");
  const [css, template, hero] = await Promise.all([
    fs.readFile(cssPath, "utf8"),
    fs.readFile(templatePath, "utf8"),
    fs.readFile(heroPath),
  ]);
  if (hero.length > 16 * 1024 * 1024) {
    throw new Error("Hero image exceeds the 16 MiB package limit");
  }
  const heroDataUrl = `data:${mimeFor(heroPath)};base64,${hero.toString("base64")}`;
  return {
    theme,
    expression: template
      .replace("__NOIR_CSS_JSON__", JSON.stringify(css))
      .replace("__NOIR_THEME_JSON__", JSON.stringify(theme))
      .replace("__NOIR_HERO_JSON__", JSON.stringify(heroDataUrl)),
  };
}

class CdpSession {
  constructor(target) {
    this.target = target;
    this.socket = new WebSocket(target.webSocketDebuggerUrl);
    this.nextId = 1;
    this.pending = new Map();
    this.listeners = new Map();
    this.closed = false;
  }

  async open() {
    await new Promise((resolve, reject) => {
      this.socket.addEventListener("open", resolve, { once: true });
      this.socket.addEventListener("error", reject, { once: true });
    });
    this.socket.addEventListener("message", (event) => this.onMessage(event));
    this.socket.addEventListener("close", () => {
      this.closed = true;
      for (const pending of this.pending.values()) pending.reject(new Error("CDP socket closed"));
      this.pending.clear();
    });
    await this.send("Runtime.enable");
    await this.send("Page.enable");
    return this;
  }

  onMessage(event) {
    const message = JSON.parse(String(event.data));
    if (message.id) {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      if (message.error) pending.reject(new Error(`${message.error.message} (${message.error.code})`));
      else pending.resolve(message.result);
      return;
    }
    for (const listener of this.listeners.get(message.method) ?? []) listener(message.params ?? {});
  }

  on(method, listener) {
    const current = this.listeners.get(method) ?? [];
    current.push(listener);
    this.listeners.set(method, current);
  }

  send(method, params = {}) {
    if (this.closed) return Promise.reject(new Error("CDP session is closed"));
    return new Promise((resolve, reject) => {
      const id = this.nextId++;
      this.pending.set(id, { resolve, reject });
      this.socket.send(JSON.stringify({ id, method, params }));
    });
  }

  async evaluate(expression) {
    const response = await this.send("Runtime.evaluate", {
      expression,
      awaitPromise: true,
      returnByValue: true,
      userGesture: false,
    });
    if (response.exceptionDetails) {
      const detail = response.exceptionDetails.exception?.description ?? response.exceptionDetails.text;
      throw new Error(`Renderer evaluation failed: ${detail}`);
    }
    return response.result?.value;
  }

  close() {
    if (!this.closed) this.socket.close();
    this.closed = true;
  }
}

async function listTargets(port) {
  const response = await fetch(`http://127.0.0.1:${port}/json/list`);
  if (!response.ok) throw new Error(`CDP target list returned HTTP ${response.status}`);
  const targets = await response.json();
  return targets.filter((target) => target.type === "page" && target.url.startsWith("app://"));
}

async function waitForTargets(port, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  let lastError = null;
  while (Date.now() < deadline) {
    try {
      const targets = await listTargets(port);
      if (targets.length > 0) return targets;
    } catch (error) {
      lastError = error;
    }
    await new Promise((resolve) => setTimeout(resolve, 350));
  }
  throw new Error(`No Codex renderer target on 127.0.0.1:${port}: ${lastError?.message ?? "timed out"}`);
}

async function connect(target, expression) {
  const session = await new CdpSession(target).open();
  if (expression) {
    await session.send("Page.addScriptToEvaluateOnNewDocument", { source: expression });
  }
  return session;
}

async function removeSession(session) {
  return session.evaluate(`(() => {
    window.__CODEX_NOIR_GOLD_DISABLED__ = true;
    const state = window.__CODEX_NOIR_GOLD_STATE__;
    if (state?.cleanup) return state.cleanup();
    document.documentElement?.classList.remove("codex-noir-gold");
    document.documentElement?.style.removeProperty("--ng-hero");
    document.getElementById("codex-noir-gold-style")?.remove();
    document.getElementById("codex-noir-gold-chrome")?.remove();
    return true;
  })()`);
}

async function verifySession(session) {
  return session.evaluate(`(() => {
    const box = (node) => {
      if (!node) return null;
      const rect = node.getBoundingClientRect();
      return { x: Math.round(rect.x), y: Math.round(rect.y), width: Math.round(rect.width), height: Math.round(rect.height) };
    };
    const home = document.querySelector(".ng-home");
    const suggestions = home?.querySelector(".group\\/home-suggestions") ?? null;
    const cards = suggestions ? [...suggestions.querySelectorAll("button")].map(box) : [];
    const chrome = document.getElementById("codex-noir-gold-chrome");
    const result = {
      installed: document.documentElement.classList.contains("codex-noir-gold"),
      version: window.__CODEX_NOIR_GOLD_STATE__?.version ?? null,
      stylePresent: Boolean(document.getElementById("codex-noir-gold-style")),
      chromePresent: Boolean(chrome),
      chromePointerEvents: chrome ? getComputedStyle(chrome).pointerEvents : null,
      homePresent: Boolean(home),
      cards,
      composer: box(document.querySelector(".composer-surface-chrome")),
      sidebar: box(document.querySelector("aside.app-shell-left-panel")),
      viewport: { width: innerWidth, height: innerHeight },
      overflowX: document.documentElement.scrollWidth > document.documentElement.clientWidth,
    };
    result.pass = result.installed && result.stylePresent && result.chromePresent &&
      result.chromePointerEvents === "none" && Boolean(result.composer) && Boolean(result.sidebar) &&
      !result.overflowX && (!result.homePresent || result.cards.length >= 2);
    return result;
  })()`);
}

async function waitForVerification(session, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  let last = null;
  while (Date.now() < deadline) {
    last = await verifySession(session);
    if (last.pass) return last;
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  return last;
}

async function capture(session, outputPath) {
  await fs.mkdir(path.dirname(outputPath), { recursive: true });
  const result = await session.send("Page.captureScreenshot", {
    format: "png",
    fromSurface: true,
    captureBeyondViewport: false,
  });
  await fs.writeFile(outputPath, Buffer.from(result.data, "base64"));
}

async function runOneShot(options) {
  const loaded = options.mode === "once" ? await loadPayload(options.themeRoot) : null;
  const targets = await waitForTargets(options.port, options.timeoutMs);
  const results = [];
  for (const target of targets) {
    const session = await connect(target, loaded?.expression ?? null);
    try {
      if (options.mode === "remove") await removeSession(session);
      if (options.mode === "once") await session.evaluate(loaded.expression);
      const result = options.mode === "remove"
        ? await session.evaluate("!document.documentElement.classList.contains('codex-noir-gold')")
        : options.mode === "once"
          ? await waitForVerification(session, options.timeoutMs)
          : await verifySession(session);
      if (options.screenshot) await capture(session, options.screenshot);
      results.push({ targetId: target.id, title: target.title, url: target.url, result });
    } finally {
      session.close();
    }
  }
  console.log(JSON.stringify({ mode: options.mode, port: options.port, targets: results }, null, 2));
  if (options.mode === "verify" && results.some((item) => !item.result.pass)) process.exitCode = 2;
}

async function runWatch(options) {
  const { expression, theme } = await loadPayload(options.themeRoot);
  const sessions = new Map();
  let stopping = false;
  let attachedOnce = false;
  let lastTargetAt = Date.now();
  const stop = () => { stopping = true; };
  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);

  while (!stopping) {
    let targets = [];
    try {
      targets = await listTargets(options.port);
    } catch (error) {
      if (!attachedOnce) console.error(`[noir-gold] ${error.message}`);
    }

    if (targets.length > 0) {
      attachedOnce = true;
      lastTargetAt = Date.now();
    } else if (attachedOnce && Date.now() - lastTargetAt >= options.idleExitMs) {
      console.log("[noir-gold] Codex session ended; injector exiting.");
      break;
    }

    const activeIds = new Set(targets.map((target) => target.id));
    for (const [id, session] of sessions) {
      if (!activeIds.has(id) || session.closed) {
        session.close();
        sessions.delete(id);
      }
    }

    for (const target of targets) {
      if (sessions.has(target.id)) continue;
      try {
        const session = await connect(target, expression);
        session.on("Page.loadEventFired", () => {
          setTimeout(() => session.evaluate(expression).catch((error) => {
            console.error(`[noir-gold] reinjection failed: ${error.message}`);
          }), 250);
        });
        await session.evaluate(expression);
        sessions.set(target.id, session);
        console.log(`[noir-gold] injected ${theme.id} into ${target.id}`);
      } catch (error) {
        console.error(`[noir-gold] target ${target.id} failed: ${error.message}`);
      }
    }
    await new Promise((resolve) => setTimeout(resolve, 850));
  }

  for (const session of sessions.values()) session.close();
}

const options = parseArgs(process.argv.slice(2));
if (options.mode === "watch") await runWatch(options);
else await runOneShot(options);
