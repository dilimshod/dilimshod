// Trips list with infinite scroll (IntersectionObserver) and a "Load more" fallback.

import { api } from "../api.js";
import { href } from "../app.js";
import { kindName, t } from "../i18n.js";
import { dayNum, duration, h, icon, km, monthYear, scoreRing, time, weekdayShort, dateTime } from "../ui.js";

const PAGE = 20;
const INFO = new Set(["trafficOfficerSeen", "roadWorkersSeen"]);
const STRONG = new Set(["pedestrianNotYielded", "redLightRunning", "stopSignIgnored"]);

export async function tripsPage(view) {
  const list = h("div.trip-list");
  const more = h("button.btn", { type: "button" }, t("trips.more"));
  const foot = h("div.load-more", more);
  view.replaceChildren(
    h("div.page-head", h("div", h("h1", t("trips.title")), h("p.sub", t("trips.sub")))),
    list, foot);

  let before = null, done = false, loading = false, lastMonth = null, count = 0;
  const io = new IntersectionObserver((entries) => { if (entries.some((e) => e.isIntersecting)) load(); },
    { rootMargin: "400px" });

  async function load() {
    if (loading || done) return;
    loading = true;
    more.disabled = true;
    try {
      const q = `api/v1/trips?limit=${PAGE}` + (before ? `&before=${encodeURIComponent(before)}` : "");
      const trips = await api(q);
      for (const tr of trips) {
        const m = monthYear(tr.startedAt);
        if (m !== lastMonth) { list.append(h("h2.month", m)); lastMonth = m; }
        list.append(row(tr));
      }
      count += trips.length;
      if (trips.length < PAGE) {
        done = true;
        io.disconnect();
        foot.replaceChildren(count ? h("span.faint", t("trips.end")) : "");
        if (!count) list.replaceChildren(h("div.empty", icon("route"), h("b", t("trips.empty")), h("span", t("chart.noDataHint"))));
      } else {
        before = trips[trips.length - 1].startedAt;
      }
    } finally {
      loading = false;
      more.disabled = false;
    }
  }
  more.addEventListener("click", load);
  await load();
  if (!done) io.observe(foot);
  document.addEventListener("rv:leave", () => io.disconnect(), { once: true });
}

function row(tr) {
  const o = (tr.origin && tr.origin.name) || t("trips.unknown");
  const d = (tr.destination && tr.destination.name) || t("trips.unknown");
  const counts = Object.entries(tr.eventCounts || {}).filter(([k, n]) => n > 0 && !INFO.has(k))
    .sort((a, b) => b[1] - a[1]);
  const chips = counts.slice(0, 3).map(([k, n]) => h(`span.ev-chip${STRONG.has(k) ? ".bad" : ".warn"}`, `${kindName(k)} · ${n}`));
  if (counts.length > 3) chips.push(h("span.ev-chip", `+${counts.length - 3}`));
  if (!counts.length) chips.push(h("span.ev-chip.ok", t("trips.noEvents")));
  return h("a.trip-row", { href: href(`/trips/${tr.id}`), "data-link": `/trips/${tr.id}` },
    h("div.trip-date", h("span.d", dayNum(tr.startedAt)), h("span.t", `${weekdayShort(tr.startedAt)} ${time(tr.startedAt)}`)),
    h("div.trip-main", { style: { minWidth: 0 } },
      h("div.trip-when-m", dateTime(tr.startedAt)),
      h("div.route", h("span", o), icon("arrow"), h("span", d)),
      h("div.trip-meta",
        h("span", icon("road"), `${km(tr.distanceMeters / 1000)} ${t("unit.km")}`),
        h("span", icon("clock"), duration(tr.durationSeconds)),
        tr.maxSpeedKmh ? h("span", icon("speed"), `${Math.round(tr.maxSpeedKmh)} ${t("unit.kmh")}`) : null)),
    h("div.ev-chips", chips),
    scoreRing(tr.score));
}
