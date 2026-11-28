// DOM helpers, icons, formatters. User data is always inserted as text (never innerHTML).

import { getLang, LOCALES, t } from "./i18n.js";

const SVG_NS = "http://www.w3.org/2000/svg";

/** h("div.card#id", {attrs}, ...children) — tiny hyperscript. */
export function h(tag, attrs, ...children) {
  const m = /^([a-z0-9-]+)((?:[.#][\w-]+)*)$/i.exec(tag);
  const el = document.createElement(m ? m[1] : tag);
  if (m && m[2]) {
    for (const part of m[2].match(/[.#][\w-]+/g)) {
      if (part[0] === ".") el.classList.add(part.slice(1));
      else el.id = part.slice(1);
    }
  }
  if (attrs && (typeof attrs !== "object" || attrs instanceof Node || Array.isArray(attrs))) {
    children.unshift(attrs);
    attrs = null;
  }
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === null || v === undefined || v === false) continue;
    if (k === "class") el.className += (el.className ? " " : "") + v;
    else if (k === "style" && typeof v === "object") {
      for (const [sk, sv] of Object.entries(v)) {
        if (sk.startsWith("--")) el.style.setProperty(sk, String(sv));
        else el.style[sk] = sv;
      }
    }
    else if (k.startsWith("on") && typeof v === "function") el.addEventListener(k.slice(2), v);
    else if (k === "text") el.textContent = v;
    else el.setAttribute(k, v === true ? "" : v);
  }
  append(el, children);
  return el;
}

function append(el, children) {
  for (const c of children.flat(Infinity)) {
    if (c === null || c === undefined || c === false) continue;
    el.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
}

export function svg(tag, attrs = {}, ...children) {
  const el = document.createElementNS(SVG_NS, tag);
  for (const [k, v] of Object.entries(attrs)) if (v !== null && v !== undefined) el.setAttribute(k, v);
  for (const c of children.flat()) if (c) el.append(c);
  return el;
}

// Icons (24×24, 2px strokes) ------------------------------------------------------------------------------------
const ICONS = {
  gauge: "M12 14l4-4M3.5 15a9 9 0 1 1 17 0M7 18h10",
  route: "M6 19a2 2 0 1 0 0-4 2 2 0 0 0 0 4zM18 9a2 2 0 1 0 0-4 2 2 0 0 0 0 4zM6 15V9a4 4 0 0 1 4-4h2M18 9v6a4 4 0 0 1-4 4h-2",
  user: "M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM4 20a8 8 0 0 1 16 0",
  sun: "M12 16a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4",
  moon: "M20 14.5A8 8 0 0 1 9.5 4 8 8 0 1 0 20 14.5z",
  arrow: "M5 12h14M13 6l6 6-6 6",
  back: "M15 18l-6-6 6-6",
  road: "M8 3L4 21M16 3l4 18M12 4v2M12 10v3M12 17v3",
  clock: "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM12 7v5l3 2",
  award: "M12 15a6 6 0 1 0 0-12 6 6 0 0 0 0 12zM8.5 13.5L7 22l5-3 5 3-1.5-8.5",
  shield: "M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6l8-3z",
  shieldCheck: "M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6l8-3zM9 12l2 2 4-4",
  speed: "M12 13l3.5-3.5M4.2 17a9 9 0 1 1 15.6 0M12 13a1 1 0 1 0 0 0",
  alert: "M12 3l10 18H2L12 3zM12 10v4M12 17.5v.01",
  check: "M5 12.5l4.5 4.5L19 7.5",
  flag: "M5 21V4M5 4h11l-2 4 2 4H5",
  pin: "M12 21s-7-6.2-7-12a7 7 0 0 1 14 0c0 5.8-7 12-7 12zM12 11.5a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5z",
  car: "M5 13l2-5a2 2 0 0 1 2-1.3h6A2 2 0 0 1 17 8l2 5M4 13h16v4H4zM6.5 17v2M17.5 17v2M7 15h.01M17 15h.01",
  phone: "M8 2h8a2 2 0 0 1 2 2v16a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2zM11 18h2",
  monitor: "M3 4h18v12H3zM8 20h8M12 16v4",
  logout: "M15 4h4v16h-4M10 8l-4 4 4 4M6 12h11",
  trash: "M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3",
  info: "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM12 11v5M12 8v.01",
  camera: "M3 8h4l2-3h6l2 3h4v11H3zM12 17a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7z",
  up: "M12 19V5M6 11l6-6 6 6",
  down: "M12 5v14M18 13l-6 6-6-6",
  flat: "M5 12h14",
  zap: "M13 2L4 14h7l-1 8 9-12h-7l1-8z",
  footprints: "M8 3c-2 0-3 2-3 5s1 5 3 5 3-2 3-5-1-5-3-5zM6 15h4v3a2 2 0 0 1-4 0v-3zM16 7c-2 0-3 2-3 5s1 5 3 5 3-2 3-5-1-5-3-5zM14 19h4",
  traffic: "M8 2h8v20H8zM12 7.5v.01M12 12v.01M12 16.5v.01",
  stop: "M8 3h8l5 5v8l-5 5H8l-5-5V8zM8 12h8",
  brake: "M12 20a8 8 0 1 0 0-16 8 8 0 0 0 0 16zM12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM3 9a10 10 0 0 0 0 6M21 9a10 10 0 0 1 0 6",
  lane: "M6 3v18M18 3v18M12 3v3M12 9v3M12 15v3",
  worker: "M12 3a3 3 0 0 0-3 3v1h6V6a3 3 0 0 0-3-3zM7 7h10M12 10v5M8 21l4-6 4 6M7 13h10",
  officer: "M12 3l7 3-1 4H6L5 6l7-3zM6 10a6 6 0 0 0 12 0M5 21a7 7 0 0 1 14 0",
  star: "M12 3l2.8 5.6 6.2.9-4.5 4.4 1 6.1-5.5-2.9L6.5 20l1-6.1L3 9.5l6.2-.9L12 3z",
  nightOwl: "M20 14.5A8 8 0 0 1 9.5 4 8 8 0 1 0 20 14.5zM15 5l.8 1.6L17.5 7l-1.7.4L15 9l-.8-1.6L12.5 7l1.7-.4z",
  gap: "M3 12h4M17 12h4M9 8l-3 4 3 4M15 8l3 4-3 4",
  lock: "M6 11h12v10H6zM8 11V7a4 4 0 0 1 8 0v4",
  sparkle: "M12 3v4M12 17v4M3 12h4M17 12h4M6 6l2.5 2.5M15.5 15.5L18 18M6 18l2.5-2.5M15.5 8.5L18 6",
};

export function icon(name, cls) {
  const s = svg("svg", { viewBox: "0 0 24 24", fill: "none", stroke: "currentColor", "stroke-width": "2",
    "stroke-linecap": "round", "stroke-linejoin": "round", "aria-hidden": "true", class: cls || null });
  s.append(svg("path", { d: ICONS[name] || ICONS.info }));
  return s;
}

export const KIND_ICON = {
  speeding: "speed", tailgating: "gap", collisionRisk: "alert", laneDeparture: "lane", redLightRunning: "traffic",
  stopSignIgnored: "stop", pedestrianNotYielded: "footprints", harshBraking: "brake", harshAcceleration: "zap",
  trafficOfficerSeen: "officer", roadWorkersSeen: "worker",
};
export const BADGE_ICON = {
  firstTrip: "flag", km100: "road", km500: "road", km1000: "route", clean10: "shieldCheck", calmDriver: "sparkle",
  safeGap: "gap", nightOwl: "nightOwl",
};

// Formatting -----------------------------------------------------------------------------------------------------
const TZ = "Asia/Tashkent";
const loc = () => LOCALES[getLang()] || "uz";
// Browsers ship little or no Uzbek locale data (Chrome prints "2026 M11 15"), so Uzbek dates are composed here and
// Uzbek numbers use the same separators as Russian (space grouping, decimal comma).
const numLoc = () => (getLang() === "uz" ? "ru-RU" : loc());
const UZ_MONTHS = ["yanvar", "fevral", "mart", "aprel", "may", "iyun", "iyul", "avgust", "sentabr", "oktabr", "noyabr", "dekabr"];
const UZ_MONTHS_SHORT = ["yan", "fev", "mar", "apr", "may", "iyn", "iyl", "avg", "sen", "okt", "noy", "dek"];
const UZ_WEEKDAYS = ["Ya", "Du", "Se", "Ch", "Pa", "Ju", "Sh"];

/** Calendar parts of ``iso`` in Asia/Tashkent. */
function parts(iso) {
  const p = {};
  for (const x of new Intl.DateTimeFormat("en-GB", { timeZone: TZ, year: "numeric", month: "numeric", day: "numeric",
    hour: "2-digit", minute: "2-digit", hourCycle: "h23", weekday: "short" }).formatToParts(new Date(iso))) p[x.type] = x.value;
  const wd = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].indexOf(p.weekday);
  return { y: +p.year, m: +p.month - 1, d: +p.day, hh: p.hour, mm: p.minute, wd };
}

export function num(v, digits = 0) {
  if (v === null || v === undefined || Number.isNaN(v)) return "—";
  return new Intl.NumberFormat(numLoc(), { maximumFractionDigits: digits, minimumFractionDigits: 0 }).format(v);
}

export function pct(v, digits = 1) {
  if (v === null || v === undefined) return "—";
  return new Intl.NumberFormat(numLoc(), { style: "percent", maximumFractionDigits: digits }).format(v);
}

export function km(v) { return v >= 100 ? num(v, 0) : num(v, 1); }

function fmt(opts) { return new Intl.DateTimeFormat(loc(), { timeZone: TZ, ...opts }); }
const uz = () => getLang() === "uz";

export function dateShort(iso) {
  if (uz()) { const p = parts(iso); return `${p.d}-${UZ_MONTHS_SHORT[p.m]}`; }
  return fmt({ day: "numeric", month: "short" }).format(new Date(iso));
}
export function dateLong(iso) {
  if (uz()) { const p = parts(iso); return `${p.y}-yil ${p.d}-${UZ_MONTHS[p.m]}`; }
  return fmt({ day: "numeric", month: "long", year: "numeric" }).format(new Date(iso));
}
export function time(iso) { const p = parts(iso); return `${p.hh}:${p.mm}`; }
export function dateTime(iso) { return `${dateShort(iso)}, ${time(iso)}`; }
export function monthYear(iso) {
  if (uz()) { const p = parts(iso); return `${p.y}-yil ${UZ_MONTHS[p.m]}`; }
  const s = fmt({ month: "long", year: "numeric" }).format(new Date(iso));
  return s.charAt(0).toUpperCase() + s.slice(1);
}
export function weekdayShort(iso) {
  if (uz()) return UZ_WEEKDAYS[parts(iso).wd];
  const s = fmt({ weekday: "short" }).format(new Date(iso));
  return s.charAt(0).toUpperCase() + s.slice(1);
}
export function dayNum(iso) { return String(parts(iso).d); }

export function duration(seconds) {
  const s = Math.max(0, Math.round(seconds || 0));
  const totalMin = Math.round(s / 60);
  const hh = Math.floor(totalMin / 60), mm = totalMin % 60;
  if (hh > 0) return `${hh} ${t("unit.h")} ${mm} ${t("unit.min")}`;
  if (mm > 0) return `${mm} ${t("unit.min")}`;
  return `${s} ${t("unit.s")}`;
}

/** "x min ago"-style relative time. */
export function ago(iso) {
  if (!iso) return t("common.never");
  const diff = (new Date(iso).getTime() - Date.now()) / 1000;
  if (uz()) {
    const a = Math.abs(diff);
    if (a < 60) return "hozirgina";
    if (a < 3600) return `${Math.round(a / 60)} daqiqa oldin`;
    if (a < 86400) return `${Math.round(a / 3600)} soat oldin`;
    if (a < 86400 * 45) return `${Math.round(a / 86400)} kun oldin`;
    return dateLong(iso);
  }
  if (Math.abs(diff) < 45) return new Intl.RelativeTimeFormat(loc(), { numeric: "auto" }).format(0, "second");
  const rtf = new Intl.RelativeTimeFormat(loc(), { numeric: "auto" });
  const abs = Math.abs(diff);
  if (abs < 60) return rtf.format(Math.round(diff), "second");
  if (abs < 3600) return rtf.format(Math.round(diff / 60), "minute");
  if (abs < 86400) return rtf.format(Math.round(diff / 3600), "hour");
  if (abs < 86400 * 45) return rtf.format(Math.round(diff / 86400), "day");
  return dateLong(iso);
}

export function scoreClass(score) { return score >= 85 ? "" : score >= 65 ? "mid" : "low"; }

export function scoreRing(score, label) {
  const s = Math.round(score ?? 0);
  return h(`div.score${scoreClass(s) ? "." + scoreClass(s) : ""}`, { style: { "--p": s }, role: "img",
    "aria-label": `${label || t("trip.score")}: ${s} / 100` }, h("span", s));
}

export function initials(name) {
  const parts = String(name || "R").trim().split(/\s+/).filter(Boolean);
  return ((parts[0] || "R")[0] + (parts[1] ? parts[1][0] : "")).toUpperCase();
}

let toastTimer;
export function toast(message) {
  let el = document.querySelector(".toast");
  if (!el) {
    el = h("div.toast", { role: "status" });
    document.body.append(el);
  }
  el.textContent = message;
  requestAnimationFrame(() => el.classList.add("show"));
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove("show"), 2600);
}

export const reducedMotion = () => window.matchMedia("(prefers-reduced-motion: reduce)").matches;

/** Loads a classic (UMD) script once. */
const loaded = new Map();
export function loadScript(src) {
  if (!loaded.has(src)) {
    loaded.set(src, new Promise((resolve, reject) => {
      const s = document.createElement("script");
      s.src = src;
      s.onload = resolve;
      s.onerror = () => { loaded.delete(src); reject(new Error("failed to load " + src)); };
      document.head.append(s);
    }));
  }
  return loaded.get(src);
}

export function loadStyle(href) {
  if (!document.querySelector(`link[href="${href}"]`)) {
    document.head.append(h("link", { rel: "stylesheet", href }));
  }
}

export function cssVar(name) {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
}
