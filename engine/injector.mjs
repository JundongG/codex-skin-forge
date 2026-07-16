import fs from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";

const MAX_THEME_BYTES = 64 * 1024;
const MAX_TEXT_ASSET_BYTES = 1024 * 1024;
const MAX_HERO_BYTES = 16 * 1024 * 1024;
const TEMPLATE_TOKENS = [
  "__NOIR_CSS_JSON__",
  "__NOIR_THEME_JSON__",
  "__NOIR_HERO_JSON__",
];

export function parseArgs(argv) {
  const options = {
    port: 0,
    mode: "watch",
    timeoutMs: 30000,
    idleExitMs: 30000,
    commandTimeoutMs: 7000,
    screenshot: null,
    themeRoot: null,
    sessionId: null,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--port") options.port = Number(argv[++index]);
    else if (arg === "--theme-root") options.themeRoot = path.resolve(argv[++index]);
    else if (arg === "--session-id") options.sessionId = String(argv[++index] ?? "");
    else if (arg === "--watch") options.mode = "watch";
    else if (arg === "--once") options.mode = "once";
    else if (arg === "--verify") options.mode = "verify";
    else if (arg === "--remove") options.mode = "remove";
    else if (arg === "--validate-theme") options.mode = "validate-theme";
    else if (arg === "--timeout-ms") options.timeoutMs = Number(argv[++index]);
    else if (arg === "--idle-exit-ms") options.idleExitMs = Number(argv[++index]);
    else if (arg === "--command-timeout-ms") options.commandTimeoutMs = Number(argv[++index]);
    else if (arg === "--screenshot") options.screenshot = path.resolve(argv[++index]);
    else throw new Error(`Unknown argument: ${arg}`);
  }
  if (!options.themeRoot) throw new Error("--theme-root is required");
  if (options.mode !== "validate-theme" &&
      (!Number.isInteger(options.port) || options.port < 1024 || options.port > 65535)) {
    throw new Error(`Invalid loopback CDP port: ${options.port}`);
  }
  if (!Number.isInteger(options.timeoutMs) || options.timeoutMs < 100 || options.timeoutMs > 120000) {
    throw new Error(`Invalid timeout: ${options.timeoutMs}`);
  }
  if (!Number.isInteger(options.idleExitMs) || options.idleExitMs < 1000 || options.idleExitMs > 300000) {
    throw new Error(`Invalid idle exit timeout: ${options.idleExitMs}`);
  }
  if (!Number.isInteger(options.commandTimeoutMs) ||
      options.commandTimeoutMs < 500 || options.commandTimeoutMs > 60000) {
    throw new Error(`Invalid CDP command timeout: ${options.commandTimeoutMs}`);
  }
  if (options.mode === "watch" && !/^[a-f0-9]{32}$/i.test(options.sessionId ?? "")) {
    throw new Error("--session-id with a 32-character hexadecimal value is required in watch mode");
  }
  return options;
}

function assertRelativeInside(target, root, label) {
  const relative = path.relative(root, target);
  if (!relative || relative.startsWith("..") || path.isAbsolute(relative)) {
    throw new Error(`${label} must stay inside theme root: ${target}`);
  }
}

async function resolveRealInside(target, rootReal, label) {
  const targetReal = await fs.realpath(target);
  assertRelativeInside(targetReal, rootReal, label);
  return targetReal;
}

function mimeFor(filename) {
  const extension = path.extname(filename).toLowerCase();
  if (extension === ".png") return "image/png";
  if (extension === ".jpg" || extension === ".jpeg") return "image/jpeg";
  throw new Error(`Unsupported hero image type: ${extension || "none"}`);
}

function assertThemeText(theme, name, maximumLength) {
  const value = theme[name];
  if (typeof value !== "string" || value.trim().length === 0 || value.length > maximumLength) {
    throw new Error(`theme.${name} must be a non-empty string of at most ${maximumLength} characters`);
  }
  if (/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u202a-\u202e\u2066-\u2069]/u.test(value)) {
    throw new Error(`theme.${name} contains disallowed control or bidirectional characters`);
  }
}

async function readLimited(filename, maximumBytes, label, encoding = null) {
  const stat = await fs.stat(filename);
  if (!stat.isFile()) throw new Error(`${label} is not a regular file`);
  if (stat.size <= 0 || stat.size > maximumBytes) {
    throw new Error(`${label} size ${stat.size} is outside the allowed range`);
  }
  return fs.readFile(filename, encoding ?? undefined);
}

function replaceExactlyOnce(source, token, replacement) {
  const first = source.indexOf(token);
  if (first < 0 || source.indexOf(token, first + token.length) >= 0) {
    throw new Error(`Renderer template must contain ${token} exactly once`);
  }
  return source.replace(token, replacement);
}

export async function loadPayload(themeRoot) {
  const rootReal = await fs.realpath(themeRoot);
  const themePath = await resolveRealInside(path.join(rootReal, "theme.json"), rootReal, "theme.json");
  const cssPath = await resolveRealInside(path.join(rootReal, "noir-gold.css"), rootReal, "noir-gold.css");
  const templatePath = await resolveRealInside(path.join(rootReal, "renderer-inject.js"), rootReal, "renderer-inject.js");
  const themeText = await readLimited(themePath, MAX_THEME_BYTES, "theme.json", "utf8");
  const theme = JSON.parse(themeText);
  if (theme.schemaVersion !== 1) throw new Error("Unsupported theme schema");
  if (theme.customizationRequired !== false) {
    throw new Error("Theme is not a completed customer theme");
  }
  if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(theme.id ?? "") || theme.id.length > 64) {
    throw new Error("theme.id must be kebab-case and at most 64 characters");
  }
  assertThemeText(theme, "name", 100);
  assertThemeText(theme, "brandTitle", 100);
  assertThemeText(theme, "brandSubtitle", 100);
  assertThemeText(theme, "headline", 100);
  assertThemeText(theme, "tagline", 100);
  assertThemeText(theme, "signature", 40);
  assertThemeText(theme, "badge", 24);
  if (typeof theme.heroAsset !== "string" || path.isAbsolute(theme.heroAsset)) {
    throw new Error("theme.heroAsset must be a relative path");
  }

  const heroPath = await resolveRealInside(path.resolve(rootReal, theme.heroAsset), rootReal, "hero asset");
  const [css, template, hero] = await Promise.all([
    readLimited(cssPath, MAX_TEXT_ASSET_BYTES, "noir-gold.css", "utf8"),
    readLimited(templatePath, MAX_TEXT_ASSET_BYTES, "renderer-inject.js", "utf8"),
    readLimited(heroPath, MAX_HERO_BYTES, "hero image"),
  ]);
  for (const token of TEMPLATE_TOKENS) {
    const first = template.indexOf(token);
    if (first < 0 || template.indexOf(token, first + token.length) >= 0) {
      throw new Error(`Renderer template must contain ${token} exactly once`);
    }
  }

  const heroDataUrl = `data:${mimeFor(heroPath)};base64,${hero.toString("base64")}`;
  let expression = replaceExactlyOnce(template, "__NOIR_CSS_JSON__", JSON.stringify(css));
  expression = replaceExactlyOnce(expression, "__NOIR_THEME_JSON__", JSON.stringify(theme));
  expression = replaceExactlyOnce(expression, "__NOIR_HERO_JSON__", JSON.stringify(heroDataUrl));
  return {
    theme,
    rootReal,
    heroPath,
    heroBytes: hero.length,
    expression,
  };
}

export function isAllowedTarget(target, port) {
  if (!target || target.type !== "page" || typeof target.url !== "string" ||
      !target.url.startsWith("app://") || typeof target.webSocketDebuggerUrl !== "string") {
    return false;
  }
  try {
    const socketUrl = new URL(target.webSocketDebuggerUrl);
    return socketUrl.protocol === "ws:" &&
      socketUrl.hostname === "127.0.0.1" &&
      Number(socketUrl.port) === Number(port);
  } catch {
    return false;
  }
}

async function fetchJson(url, timeoutMs) {
  const response = await fetch(url, {
    redirect: "error",
    signal: AbortSignal.timeout(timeoutMs),
  });
  if (!response.ok) throw new Error(`CDP endpoint returned HTTP ${response.status}`);
  return response.json();
}

class CdpSession {
  constructor(target, commandTimeoutMs) {
    this.target = target;
    this.commandTimeoutMs = commandTimeoutMs;
    this.socket = new WebSocket(target.webSocketDebuggerUrl);
    this.nextId = 1;
    this.pending = new Map();
    this.listeners = new Map();
    this.closed = false;
  }

  failAll(error) {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.pending.clear();
  }

  async open() {
    await new Promise((resolve, reject) => {
      const cleanup = () => {
        clearTimeout(timer);
        this.socket.removeEventListener("open", opened);
        this.socket.removeEventListener("error", failed);
      };
      const opened = () => {
        cleanup();
        resolve();
      };
      const failed = () => {
        cleanup();
        reject(new Error("CDP WebSocket failed to open"));
      };
      const timer = setTimeout(() => {
        cleanup();
        try { this.socket.close(); } catch {}
        reject(new Error("CDP WebSocket open timed out"));
      }, this.commandTimeoutMs);
      this.socket.addEventListener("open", opened, { once: true });
      this.socket.addEventListener("error", failed, { once: true });
    });
    this.socket.addEventListener("message", (event) => this.onMessage(event));
    this.socket.addEventListener("error", () => this.failAll(new Error("CDP WebSocket error")));
    this.socket.addEventListener("close", () => {
      this.closed = true;
      this.failAll(new Error("CDP WebSocket closed"));
    });
    await this.send("Runtime.enable");
    await this.send("Page.enable");
    return this;
  }

  onMessage(event) {
    let message;
    try {
      message = JSON.parse(String(event.data));
    } catch {
      this.failAll(new Error("CDP returned invalid JSON"));
      this.close();
      return;
    }
    if (message.id) {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      clearTimeout(pending.timer);
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
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`CDP command timed out: ${method}`));
      }, this.commandTimeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      try {
        this.socket.send(JSON.stringify({ id, method, params }));
      } catch (error) {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(error);
      }
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
    if (this.closed) return;
    this.closed = true;
    this.failAll(new Error("CDP session closed"));
    try { this.socket.close(); } catch {}
  }
}

async function listTargets(port, timeoutMs) {
  const targets = await fetchJson(`http://127.0.0.1:${port}/json/list`, timeoutMs);
  if (!Array.isArray(targets)) throw new Error("CDP target list is not an array");
  return targets.filter((target) => isAllowedTarget(target, port));
}

async function waitForTargets(port, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  let lastError = null;
  while (Date.now() < deadline) {
    try {
      const targets = await listTargets(port, Math.min(1500, timeoutMs));
      if (targets.length > 0) return targets;
    } catch (error) {
      lastError = error;
    }
    await new Promise((resolve) => setTimeout(resolve, 350));
  }
  throw new Error(`No safe Codex renderer target on 127.0.0.1:${port}: ${lastError?.message ?? "timed out"}`);
}

async function connect(target, expression, commandTimeoutMs) {
  const session = await new CdpSession(target, commandTimeoutMs).open();
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
      modalOpen: Boolean(document.querySelector('[role="dialog"]')),
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
    const session = await connect(target, loaded?.expression ?? null, options.commandTimeoutMs);
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
      targets = await listTargets(options.port, Math.min(1500, options.commandTimeoutMs));
    } catch (error) {
      if (!attachedOnce) console.error(`[codex-skin-forge] ${error.message}`);
    }

    if (targets.length > 0) {
      attachedOnce = true;
      lastTargetAt = Date.now();
    } else if (attachedOnce && Date.now() - lastTargetAt >= options.idleExitMs) {
      console.log("[codex-skin-forge] Codex session ended; injector exiting.");
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
        const session = await connect(target, expression, options.commandTimeoutMs);
        session.on("Page.loadEventFired", () => {
          setTimeout(() => session.evaluate(expression).catch((error) => {
            console.error(`[codex-skin-forge] reinjection failed: ${error.message}`);
          }), 250);
        });
        await session.evaluate(expression);
        sessions.set(target.id, session);
        console.log(`[codex-skin-forge] injected ${theme.id} for session ${options.sessionId} into ${target.id}`);
      } catch (error) {
        console.error(`[codex-skin-forge] target ${target.id} failed: ${error.message}`);
      }
    }
    await new Promise((resolve) => setTimeout(resolve, 850));
  }

  for (const session of sessions.values()) session.close();
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.mode === "validate-theme") {
    const loaded = await loadPayload(options.themeRoot);
    console.log(JSON.stringify({
      mode: options.mode,
      themeId: loaded.theme.id,
      themeVersion: loaded.theme.version,
      heroBytes: loaded.heroBytes,
    }, null, 2));
  } else if (options.mode === "watch") {
    await runWatch(options);
  } else {
    await runOneShot(options);
  }
}

const invokedPath = process.argv[1] ? pathToFileURL(path.resolve(process.argv[1])).href : null;
if (invokedPath === import.meta.url) {
  try {
    await main();
  } catch (error) {
    console.error(`[codex-skin-forge] ${error?.stack ?? error}`);
    process.exitCode = 1;
  }
}
