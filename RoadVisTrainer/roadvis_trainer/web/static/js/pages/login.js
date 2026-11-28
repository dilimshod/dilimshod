// Login: a big QR in a frame, scanned with the RoadVis app (CABINET_API.md section 4). Auto-renews, live status.

import { api, ApiError } from "../api.js";
import { langSwitch, navigate, resetSession, themeToggle } from "../app.js";
import { t } from "../i18n.js";
import { h, icon, loadScript, svg } from "../ui.js";

const POLL_MS = 2000;

function qrSvg(text) {
  const qr = window.qrcode(0, "H");
  qr.addData(text);
  qr.make();
  const n = qr.getModuleCount();
  const finder = (r, c) => (r < 7 && c < 7) || (r < 7 && c >= n - 7) || (r >= n - 7 && c < 7);
  let d = "";
  for (let r = 0; r < n; r++) {
    for (let c = 0; c < n; c++) {
      if (!finder(r, c) && qr.isDark(r, c)) d += `M${c + 0.08},${r + 0.08}h0.84v0.84h-0.84z`;
    }
  }
  const s = svg("svg", { viewBox: `-1 -1 ${n + 2} ${n + 2}`, class: "code", role: "img", "aria-label": t("login.qrAlt"),
    "shape-rendering": "geometricPrecision" });
  s.append(svg("path", { d, fill: "#021941" }));
  for (const [x, y] of [[0, 0], [n - 7, 0], [0, n - 7]]) {
    s.append(svg("rect", { x: x + 0.5, y: y + 0.5, width: 6, height: 6, rx: 1.6, fill: "none", stroke: "#021941", "stroke-width": 1 }));
    s.append(svg("rect", { x: x + 2, y: y + 2, width: 3, height: 3, rx: 0.8, fill: "#0a6e8a" }));
  }
  return s;
}

export function loginPage() {
  const inner = h("div.qr-inner.stale");
  const frame = h("div.qr-frame",
    inner,
    h("span.qr-corner.tl"), h("span.qr-corner.tr"), h("span.qr-corner.bl"), h("span.qr-corner.br"));
  const statusText = h("span", t("common.loading"));
  const status = h("div.status", { role: "status", "aria-live": "polite" }, h("span.live"), statusText);
  const timerText = h("span.num", "");
  const bar = h("i");
  const renewBtn = h("button.btn", { type: "button", style: { padding: "6px 12px", fontSize: "13px" } }, t("login.renew"));
  const timer = h("div.timer", h("div.timer-bar", bar), timerText, renewBtn);

  let ch = null, deadline = 0, ttl = 120, pollTimer = null, tickTimer = null, alive = true, busy = false;

  function setStatus(text, kind) {
    statusText.textContent = text;
    status.className = "status" + (kind ? " " + kind : "");
  }

  function stop() {
    alive = false;
    clearTimeout(pollTimer);
    clearInterval(tickTimer);
  }
  document.addEventListener("rv:leave", stop, { once: true });

  async function create(reason) {
    if (!alive || busy) return;
    busy = true;
    clearTimeout(pollTimer);
    inner.classList.add("stale");
    if (reason) setStatus(t(reason), reason === "login.denied" ? "bad" : "");
    try {
      await loadScript("static/vendor/qrcode/qrcode.js");
      ch = await api("api/v1/auth/qr", { method: "POST" });
      ttl = Math.min(120, Math.max(10, (new Date(ch.expiresAt).getTime() - Date.now()) / 1000 || 120));
      deadline = Date.now() + ttl * 1000;
      inner.replaceChildren(qrSvg(ch.qr), h("div.qr-logo", h("img", { src: "static/img/logo.png", alt: "" })),
        h("div.qr-beam"));
      inner.classList.remove("stale");
      setStatus(t("login.waiting"));
      schedulePoll();
    } catch (e) {
      setStatus(t(e instanceof ApiError && e.status === 429 ? "login.limited" : "login.error"), "bad");
      pollTimer = setTimeout(() => { busy = false; create(); }, e instanceof ApiError && e.status === 429 ? 30000 : 5000);
      return;
    } finally {
      busy = false;
    }
  }

  function schedulePoll() {
    clearTimeout(pollTimer);
    if (alive) pollTimer = setTimeout(poll, POLL_MS);
  }

  async function poll() {
    if (!alive || !ch) return;
    let res;
    try {
      res = await api(`api/v1/auth/qr/${ch.challengeId}`);
    } catch (e) {
      if (e instanceof ApiError && e.status === 404) return create("login.expired");
      setStatus(t("login.error"), "bad");
      return schedulePoll();
    }
    if (!alive) return;
    if (res.status === "approved") {
      stop();
      setStatus(t("login.approved"), "ok");
      inner.append(h("div.qr-overlay", { style: { background: "rgba(255,255,255,.92)" } },
        h("div", h("div.ok", icon("check")), t("login.approved"))));
      try { resetSession(await api("api/v1/me")); } catch (e) { resetSession(null); }
      setTimeout(() => navigate("/", { replace: true }), 900);
      return;
    }
    if (res.status === "expired") return create("login.expired");
    if (res.status === "denied") return create("login.denied");
    schedulePoll();
  }

  function tick() {
    if (!ch) return;
    const left = Math.max(0, (deadline - Date.now()) / 1000);
    bar.style.transform = `scaleX(${left / ttl})`;
    timerText.textContent = t("login.renewIn", { s: Math.ceil(left) });
    if (left <= 0 && !busy) create("login.expired");
  }
  tickTimer = setInterval(tick, 500);
  renewBtn.addEventListener("click", () => create());

  const steps = h("ol.steps", { "aria-label": t("login.steps") },
    [1, 2, 3, 4].map((i) => h("li", h("span.n", { "aria-hidden": "true" }, String(i)),
      h("div", h("b", t(`login.step${i}`)), h("span", t(`login.step${i}s`))))));

  const page = h("div.login",
    h("div.login-top",
      h("a.brand", { href: "./", "data-link": "/login" },
        h("img", { src: "static/img/logo.png", alt: "", width: 40, height: 40 }),
        h("div", h("div.brand-name", "RoadVis"), h("div.brand-sub", t("app.cabinet")))),
      h("div.prefs", langSwitch(), themeToggle())),
    h("section.login-copy.reveal",
      h("h1", t("login.title")),
      h("p.lead", t("login.lead")),
      steps),
    h("section.qr-wrap.reveal", frame, status, timer, h("p.login-note", t("login.note"))));

  create();
  return page;
}
