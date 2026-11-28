// Trip detail: map (track coloured by speed vs limit, event markers), speed/limit chart, events list.

import { api, ApiError } from "../api.js";
import { href, navigate } from "../app.js";
import { speedChart, speedLegend } from "../charts.js";
import { kindName, t } from "../i18n.js";
import { eventDetail, legend, tripMap } from "../map.js";
import { dateLong, duration, h, icon, KIND_ICON, km, num, scoreRing, time, toast } from "../ui.js";

export async function tripPage(view, route) {
  const id = decodeURIComponent(route.split("/")[2] || "");
  const back = h("a.back", { href: href("/trips"), "data-link": "/trips" }, icon("back"), t("trip.back"));
  view.replaceChildren(back, h("div.skel", { style: { height: "60px", marginBottom: "18px" } }),
    h("div.skel", { style: { height: "460px", borderRadius: "22px" } }));
  let trip;
  try {
    trip = await api(`api/v1/trips/${encodeURIComponent(id)}`);
  } catch (e) {
    if (e instanceof ApiError && e.status === 404) {
      view.replaceChildren(back, h("div.empty", icon("route"), h("b", t("trip.notFound"))));
      return;
    }
    throw e;
  }

  const o = (trip.origin && trip.origin.name) || t("trips.unknown");
  const d = (trip.destination && trip.destination.name) || t("trips.unknown");
  const head = h("div.trip-hero",
    h("div",
      h("h1.route-big", h("span", o), icon("arrow"), h("span", d)),
      h("p.sub", { style: { marginTop: "8px" } },
        `${dateLong(trip.startedAt)}, ${time(trip.startedAt)}–${time(trip.endedAt)}`,
        trip.startedWithNavigation ? ` · ${t("trip.nav")}` : "")),
    scoreRing(trip.score));

  const stats = h("div.stat-strip",
    stat("trip.distance", km(trip.distanceMeters / 1000), t("unit.km")),
    stat("trip.duration", duration(trip.durationSeconds), ""),
    stat("trip.avgSpeed", trip.avgSpeedKmh !== null && trip.avgSpeedKmh !== undefined ? num(trip.avgSpeedKmh) : "—", t("unit.kmh")),
    stat("trip.maxSpeed", trip.maxSpeedKmh !== null && trip.maxSpeedKmh !== undefined ? num(trip.maxSpeedKmh) : "—", t("unit.kmh")),
    stat("trip.score", num(trip.score), "/ 100"),
    stat("trip.points", `+${num(trip.points)}`, ""));

  // Map
  const mapEl = h("div.map", { role: "region", "aria-label": t("trip.map") });
  const mapCard = h("section.card.map-card", mapEl, trip.track && trip.track.length ? legend() : null);
  if (!trip.track || trip.track.length < 2) {
    mapCard.replaceChildren(h("div.empty", { style: { margin: "18px" } }, icon("pin"), h("b", t("trip.noTrack"))));
  }

  // Speed chart
  const chartEl = h("div.chart.tall");
  const hasSpeed = (trip.track || []).some((r) => r[3] !== null && r[3] !== undefined);
  const speedCard = h("section.card.span-7",
    h("div.card-head", h("h2", t("trip.speedChart")), h("span.hint", t("trip.speedChartHint"))),
    hasSpeed ? [speedLegend(), chartEl] : h("div.empty", icon("speed"), h("b", t("trip.noTrack"))));

  // Events
  const evs = trip.events || [];
  const evCard = h("section.card.span-5",
    h("div.card-head", h("h2", t("trip.events")), h("span.hint", String(evs.length))),
    evs.length ? h("div.ev-list", evs.map((e) => h("div.ev-item",
      h("span.tm", time(e.at)),
      h(`span.dot.${e.severity}`, icon(KIND_ICON[e.kind] || "alert")),
      h("div.what", kindName(e.kind), h("small", [t(`sev.${e.severity}`), eventDetail(e)].filter(Boolean).join(" · "))),
      h("span.sp", e.speedKmh !== null && e.speedKmh !== undefined ? `${num(e.speedKmh)} ${t("unit.kmh")}` : ""))))
      : h("div.empty", icon("shieldCheck"), h("b", t("trip.noEvents"))),
    trip.avgLeadDistanceMeters ? h("p.faint", { style: { marginTop: "14px", fontSize: "13px" } },
      t("trip.gap", { v: `${num(trip.avgLeadDistanceMeters, 1)} ${t("unit.m")}` })) : null);

  const del = h("button.btn.danger", { type: "button" }, icon("trash"), t("trip.delete"));
  del.addEventListener("click", () => confirmDelete(trip.id));

  view.replaceChildren(back, head, stats, mapCard,
    h("div.grid.ov-grid", { style: { marginTop: "18px" } }, speedCard, evCard),
    h("div", { style: { display: "flex", justifyContent: "flex-end", marginTop: "18px" } }, del));

  if (trip.track && trip.track.length >= 2) tripMap(mapEl, trip).catch((e) => console.error(e));
  if (hasSpeed) speedChart(chartEl, trip.track);
}

function stat(key, value, unit) {
  return h("div.stat", h("div.k", t(key)), h("div.v", value, unit ? h("small", unit) : null));
}

function confirmDelete(id) {
  const dlg = h("dialog", { "aria-labelledby": "dlg-title" },
    h("h2#dlg-title", t("trip.deleteTitle")),
    h("p", t("trip.deleteText")));
  const cancel = h("button.btn", { type: "button", onclick: () => dlg.close() }, t("common.cancel"));
  const ok = h("button.btn.danger.solid", { type: "button" }, icon("trash"), t("common.delete"));
  ok.addEventListener("click", async () => {
    ok.disabled = true;
    try {
      await api(`api/v1/trips/${encodeURIComponent(id)}`, { method: "DELETE" });
      dlg.close();
      toast(t("trip.deleted"));
      navigate("/trips");
    } catch (e) {
      ok.disabled = false;
      toast(t("common.error"));
    }
  });
  dlg.append(h("div.dlg-actions", cancel, ok));
  dlg.addEventListener("close", () => dlg.remove());
  document.body.append(dlg);
  dlg.showModal();
}
