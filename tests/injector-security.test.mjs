import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { isAllowedTarget, loadPayload, parseArgs } from "../engine/injector.mjs";

assert.throws(
  () => parseArgs(["--watch", "--port", "9335", "--theme-root", "."]),
  /session-id/,
);
assert.throws(
  () => parseArgs(["--validate-theme", "--theme-root", ".", "--timeout-ms", "0"]),
  /Invalid timeout/,
);
assert.equal(
  parseArgs(["--validate-theme", "--theme-root", "."]).mode,
  "validate-theme",
);

const safeTarget = {
  type: "page",
  url: "app://codex/home",
  webSocketDebuggerUrl: "ws://127.0.0.1:9335/devtools/page/abc",
};
assert.equal(isAllowedTarget(safeTarget, 9335), true);
assert.equal(isAllowedTarget({ ...safeTarget, url: "https://example.com" }, 9335), false);
assert.equal(
  isAllowedTarget({ ...safeTarget, webSocketDebuggerUrl: "ws://example.com:9335/devtools/page/abc" }, 9335),
  false,
);
assert.equal(
  isAllowedTarget({ ...safeTarget, webSocketDebuggerUrl: "ws://127.0.0.1:9444/devtools/page/abc" }, 9335),
  false,
);

const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), "codex-skin-injector-test-"));
try {
  await fs.mkdir(path.join(tempRoot, "assets"));
  const theme = {
    schemaVersion: 1,
    id: "test-client",
    name: "Test Client Skin",
    version: "0.3.1",
    customizationRequired: false,
    brandTitle: "Test Client",
    brandSubtitle: "Limited Edition",
    headline: "Build something",
    tagline: "Local test",
    signature: "TEST",
    badge: "EXCLUSIVE",
    heroAsset: "assets/customer-hero.png",
  };
  const template = "((css, theme, hero) => true)(__NOIR_CSS_JSON__, __NOIR_THEME_JSON__, __NOIR_HERO_JSON__);";
  const onePixelPng = Buffer.from(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z1Z8AAAAASUVORK5CYII=",
    "base64",
  );
  await Promise.all([
    fs.writeFile(path.join(tempRoot, "theme.json"), JSON.stringify(theme)),
    fs.writeFile(path.join(tempRoot, "noir-gold.css"), ":root { color: white; }"),
    fs.writeFile(path.join(tempRoot, "renderer-inject.js"), template),
    fs.writeFile(path.join(tempRoot, "assets", "customer-hero.png"), onePixelPng),
  ]);

  const loaded = await loadPayload(tempRoot);
  assert.equal(loaded.theme.id, "test-client");
  assert.equal(loaded.expression.includes("__NOIR_"), false);

  await fs.writeFile(path.join(tempRoot, "renderer-inject.js"), `${template}\n${template}`);
  await assert.rejects(() => loadPayload(tempRoot), /exactly once/);

  await fs.writeFile(path.join(tempRoot, "renderer-inject.js"), template);
  await fs.writeFile(path.join(tempRoot, "theme.json"), JSON.stringify({ ...theme, heroAsset: path.join(tempRoot, "outside.png") }));
  await assert.rejects(() => loadPayload(tempRoot), /relative path/);
} finally {
  await fs.rm(tempRoot, { recursive: true, force: true });
}

console.log("Injector security tests passed.");
