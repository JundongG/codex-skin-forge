((cssText, theme, heroDataUrl) => {
  const STATE_KEY = "__CODEX_NOIR_GOLD_STATE__";
  const STYLE_ID = "codex-noir-gold-style";
  const CHROME_ID = "codex-noir-gold-chrome";
  const ROOT_CLASS = "codex-noir-gold";

  const previous = window[STATE_KEY];
  if (previous?.cleanup) previous.cleanup();
  window.__CODEX_NOIR_GOLD_DISABLED__ = false;

  const addText = (parent, tagName, className, value) => {
    const node = document.createElement(tagName);
    if (className) node.className = className;
    node.textContent = String(value ?? "");
    parent.append(node);
    return node;
  };

  const createChrome = () => {
    const chrome = document.createElement("div");
    chrome.id = CHROME_ID;
    chrome.setAttribute("aria-hidden", "true");

    const brand = document.createElement("div");
    brand.className = "ng-brand";
    addText(brand, "span", "ng-brand-mark", "✦");
    const copy = document.createElement("span");
    addText(copy, "b", "", theme.brandTitle);
    addText(copy, "small", "", theme.brandSubtitle);
    brand.append(copy);

    const signature = document.createElement("div");
    signature.className = "ng-signature";
    addText(signature, "span", "", theme.signature);

    const badge = document.createElement("div");
    badge.className = "ng-badge";
    addText(badge, "span", "", theme.badge);

    const headline = document.createElement("div");
    headline.className = "ng-headline";
    addText(headline, "strong", "", theme.headline);
    addText(headline, "span", "", theme.tagline);

    const sparkles = document.createElement("div");
    sparkles.className = "ng-sparkles";
    for (let index = 0; index < 8; index += 1) sparkles.append(document.createElement("i"));

    const frame = document.createElement("div");
    frame.className = "ng-photo-frame";

    chrome.append(brand, signature, badge, headline, sparkles, frame);
    return chrome;
  };

  const findHome = () => document.querySelector('[role="main"]:has([data-testid="home-icon"])');

  const ensure = () => {
    if (window.__CODEX_NOIR_GOLD_DISABLED__) return;
    const root = document.documentElement;
    if (!root || !document.body) return;
    root.classList.add(ROOT_CLASS);
    root.style.setProperty("--ng-hero", `url("${heroDataUrl}")`);

    let style = document.getElementById(STYLE_ID);
    if (!style) {
      style = document.createElement("style");
      style.id = STYLE_ID;
      document.head.append(style);
    }
    if (style.textContent !== cssText) style.textContent = cssText;

    let chrome = document.getElementById(CHROME_ID);
    if (!chrome) {
      chrome = createChrome();
      document.body.append(chrome);
    }

    document.querySelectorAll(".ng-home").forEach((node) => node.classList.remove("ng-home"));
    const home = findHome();
    if (home) {
      home.classList.add("ng-home");
      const rect = home.getBoundingClientRect();
      chrome.style.setProperty("--ng-main-left", `${Math.max(0, Math.round(rect.left))}px`);
      chrome.style.setProperty("--ng-main-top", `${Math.max(0, Math.round(rect.top))}px`);
      chrome.style.setProperty("--ng-main-width", `${Math.max(0, Math.round(rect.width))}px`);
      chrome.style.setProperty("--ng-main-height", `${Math.max(0, Math.round(rect.height))}px`);
      chrome.classList.add("ng-home-visible");
    } else {
      chrome.classList.remove("ng-home-visible");
    }
    chrome.classList.toggle("ng-modal-open", Boolean(document.querySelector('[role="dialog"]')));
  };

  const state = {
    version: String(theme.version ?? "unknown"),
    observer: null,
    timer: null,
    scheduled: null,
    cleanup: () => {
      window.__CODEX_NOIR_GOLD_DISABLED__ = true;
      state.observer?.disconnect();
      if (state.timer) clearInterval(state.timer);
      if (state.scheduled) clearTimeout(state.scheduled);
      window.removeEventListener("resize", schedule);
      document.documentElement?.classList.remove(ROOT_CLASS);
      document.documentElement?.style.removeProperty("--ng-hero");
      document.getElementById(STYLE_ID)?.remove();
      document.getElementById(CHROME_ID)?.remove();
      document.querySelectorAll(".ng-home").forEach((node) => node.classList.remove("ng-home"));
      return true;
    },
  };

  const schedule = () => {
    if (state.scheduled || window.__CODEX_NOIR_GOLD_DISABLED__) return;
    state.scheduled = setTimeout(() => {
      state.scheduled = null;
      ensure();
    }, 80);
  };

  state.observer = new MutationObserver(schedule);
  state.observer.observe(document.documentElement, { childList: true, subtree: true });
  window.addEventListener("resize", schedule, { passive: true });
  state.timer = setInterval(ensure, 5000);
  window[STATE_KEY] = state;
  ensure();
  return true;
})(__NOIR_CSS_JSON__, __NOIR_THEME_JSON__, __NOIR_HERO_JSON__);
