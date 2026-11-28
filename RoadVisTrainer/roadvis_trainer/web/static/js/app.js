// RoadVis driver cabinet — single-page app (no build step). Routes are paths under <base href>:
// /login, / (overview), /trips, /trips/<id>, /profile, /admin, /qr.

import { api, ApiError } from "./api.js";
import { disposeAll, redrawAll } from "./charts.js";
import { initLang, LANGS, setLang, getLang, t } from "./i18n.js";
import { h, icon, initials } from "./ui.js";

const BASE = new URL(document.baseURI).pathname;   // "/roadvis/" or "/"
const app = document.getElementById("app");

export const state = { me: null, days: 30 };
try { state.days = Number(localStorage.getItem("rv.days")) || 30; } catch (e) { /* ignore */ }
if (![30, 90, 365].includes(state.days)) state.days = 30;

export function route() {
  let p = location.pathname;
  if (p.startsWith(BASE)) p = "/" + p.slice(BASE.length);
  return p.replace(/\/+$/, "") || "/";
}

export function href(path) { return BASE + path.replace(/^\//, ""); }

export function navigate(path, { replace = false } = {}) {
  const url = href(path);
  if (replace) history.replaceState({}, "", url);
  else history.pushState({}, "", url);
  render();
}

document.addEventListener("click", (ev) => {
  const a = ev.target.closest("a[data-link]");
  if (!a || ev.metaKey || ev.ctrlKey || ev.shiftKey || ev.button !== 0) return;
  ev.preventDefault();
  navigate(a.getAttribute("data-link"));
});
window.addEventListener("popstate", () => render());

// Preferences ----------------------------------------------------------------------------------------------------
export function langSwitch() {
  const seg = h("div.seg", { role: "group", "aria-label": t("lang.label") });
  for (const l of LANGS) {
    seg.append(h("button", { type: "button", "aria-pressed": String(l === getLang()), lang: l,
      onclick: () => { setLang(l); render(); } }, l.toUpperCase()));
  }
  return seg;
}

export function themeToggle() {
  const dark = document.documentElement.getAttribute("data-theme") !== "light";
  return h("button.icon-btn", { type: "button", "aria-label": t("theme.toggle"), title: t("theme.toggle"),
    onclick: (ev) => {
      const next = document.documentElement.getAttribute("data-theme") === "light" ? "dark" : "light";
      document.documentElement.setAttribute("data-theme", next);
      try { localStorage.setItem("rv.theme", next); } catch (e) { /* ignore */ }
      ev.currentTarget.replaceWith(themeToggle());
      document.dispatchEvent(new CustomEvent("rv:theme"));
      redrawAll();
    } }, icon(dark ? "sun" : "moon"));
}

// Shell ----------------------------------------------------------------------------------------------------------
const NAV = [
  { path: "/", key: "nav.overview", icon: "gauge" },
  { path: "/trips", key: "nav.trips", icon: "route" },
  { path: "/profile", key: "nav.profile", icon: "user" },
];

function isActive(path) {
  const r = route();
  return path === "/" ? r === "/" : r === path || r.startsWith(path + "/");
}

function brand() {
  return h("a.brand", { href: href("/"), "data-link": "/" },
    h("img", { src: "static/img/logo.png", alt: "", width: 40, height: 40 }),
    h("div", h("div.brand-name", "RoadVis"), h("div.brand-sub", t("app.cabinet"))));
}

function shell(view) {
  const me = state.me;
  const navLinks = (cls) => NAV.map((n) => h("a", { href: href(n.path), "data-link": n.path, class: cls || null,
    "aria-current": isActive(n.path) ? "page" : null }, icon(n.icon), h("span", t(n.key))));
  const rail = h("aside.rail",
    brand(),
    h("nav.nav", { "aria-label": t("nav.main") }, navLinks()),
    h("div.rail-foot",
      h("div.prefs", langSwitch(), themeToggle()),
      me ? h("a.driver-chip", { href: href("/profile"), "data-link": "/profile" },
        h("div.avatar", initials(me.driverName)),
        h("div", { style: { minWidth: 0 } }, h("div.name", me.driverName), h("div.lvl", t("level.n", { n: me.level })))) : null));
  const top = h("header.topbar", brand(), h("div.prefs", langSwitch(), themeToggle()));
  const tabbar = h("nav.tabbar", { "aria-label": t("nav.main") }, navLinks());
  const main = h("main.main#main", view);
  return h("div.shell", rail, top, main, tabbar);
}

// Rendering ------------------------------------------------------------------------------------------------------
let renderSeq = 0;

export async function render() {
  const seq = ++renderSeq;
  disposeAll();
  document.dispatchEvent(new CustomEvent("rv:leave"));
  const r = route();
  document.title = "RoadVis — " + t("app.cabinet");

  if (r === "/qr") {
    const { qrInfoPage } = await import("./pages/qr.js");
    if (seq === renderSeq) app.replaceChildren(qrInfoPage());
    return;
  }
  if (r === "/admin") {
    const { adminPage } = await import("./pages/admin.js");
    if (seq === renderSeq) app.replaceChildren(await adminPage());
    return;
  }
  if (r === "/login") {
    const { loginPage } = await import("./pages/login.js");
    if (seq === renderSeq) app.replaceChildren(loginPage());
    return;
  }

  if (!state.me) {
    try {
      state.me = await api("api/v1/me");
    } catch (e) {
      if (e instanceof ApiError && e.status === 401) {
        if (seq === renderSeq) navigate("/login", { replace: true });
        return;
      }
      if (seq === renderSeq) app.replaceChildren(errorView());
      return;
    }
  }
  if (seq !== renderSeq) return;

  let page;
  if (r === "/") page = (await import("./pages/overview.js")).overviewPage;
  else if (r === "/trips") page = (await import("./pages/trips.js")).tripsPage;
  else if (r.startsWith("/trips/")) page = (await import("./pages/trip.js")).tripPage;
  else if (r === "/profile") page = (await import("./pages/profile.js")).profilePage;
  else { navigate("/", { replace: true }); return; }
  if (seq !== renderSeq) return;
  const view = h("div.view-enter");
  app.replaceChildren(shell(view));
  window.scrollTo(0, 0);
  try {
    await page(view, r);
  } catch (e) {
    if (e instanceof ApiError && e.status === 401) { state.me = null; navigate("/login", { replace: true }); return; }
    console.error(e);
    view.replaceChildren(errorView());
  }
}

export function errorView() {
  return h("div.empty", { style: { margin: "40px auto", maxWidth: "460px" } }, icon("alert"), h("b", t("common.error")),
    h("button.btn", { type: "button", onclick: () => render() }, t("common.retry")));
}

/** Called after login / logout / profile changes. */
export function resetSession(me = null) { state.me = me; }

initLang();
render();
