// Trip map: vendored MapLibre GL JS + OpenFreeMap vector styles (dark / positron). The track is coloured by speed
// versus the speed limit; events are markers with popups; start and finish are pins.

import { kindName, t } from "./i18n.js";
import { h, icon, KIND_ICON, loadScript, loadStyle, num, time } from "./ui.js";

const STYLES = {
  dark: "https://tiles.openfreemap.org/styles/dark",
  light: "https://tiles.openfreemap.org/styles/positron",
};
export const TRACK_COLORS = {
  dark: { ok: "#19e3ec", over: "#ffb020", over2: "#ff5d62", unknown: "#7c93b5" },
  light: { ok: "#0a9fb0", over: "#e08a00", over2: "#d23a40", unknown: "#7a8aa5" },
};

function theme() { return document.documentElement.getAttribute("data-theme") === "light" ? "light" : "dark"; }

export async function ensureMapLibre() {
  loadStyle("static/vendor/maplibre/maplibre-gl.css");
  await loadScript("static/vendor/maplibre/maplibre-gl.js");
  return window.maplibregl;
}

function state(row) {
  const [, , , speed, limit] = row;
  if (speed === null || speed === undefined || limit === null || limit === undefined) return "unknown";
  if (speed <= limit) return "ok";
  return speed <= limit + 10 ? "over" : "over2";
}

/** Splits the track into runs of the same state (each run shares its end point with the next). */
export function trackSegments(track) {
  const features = [];
  let cur = null;
  for (let i = 0; i < track.length; i++) {
    const r = track[i];
    const st = i === 0 ? state(track[1] || r) : state(r);
    const pt = [r[1], r[0]];
    if (!cur || cur.properties.state !== st) {
      if (cur) cur.geometry.coordinates.push(pt);
      cur = { type: "Feature", properties: { state: st }, geometry: { type: "LineString", coordinates: cur ? [cur.geometry.coordinates.at(-1), pt] : [pt] } };
      features.push(cur);
    } else {
      cur.geometry.coordinates.push(pt);
    }
  }
  return { type: "FeatureCollection", features: features.filter((f) => f.geometry.coordinates.length > 1) };
}

export function legend() {
  const c = TRACK_COLORS[theme()];
  return h("div.map-legend", { "aria-hidden": "true" },
    h("span", h("i", { style: { background: c.ok } }), t("legend.ok")),
    h("span", h("i", { style: { background: c.over } }), t("legend.over")),
    h("span", h("i", { style: { background: c.over2 } }), t("legend.over2")),
    h("span", h("i", { style: { background: c.unknown } }), t("legend.unknown")));
}

export async function tripMap(container, trip) {
  const maplibregl = await ensureMapLibre();
  if (!container.isConnected) return null;
  const track = trip.track || [];
  const lons = track.map((r) => r[1]), lats = track.map((r) => r[0]);
  const bounds = track.length
    ? [[Math.min(...lons), Math.min(...lats)], [Math.max(...lons), Math.max(...lats)]]
    : [[69.15, 41.25], [69.40, 41.38]];
  const map = new maplibregl.Map({
    container, style: STYLES[theme()], bounds, fitBoundsOptions: { padding: 48 },
    attributionControl: { compact: true }, cooperativeGestures: window.matchMedia("(pointer: coarse)").matches,
    dragRotate: false, pitchWithRotate: false,
  });
  map.addControl(new maplibregl.NavigationControl({ showCompass: false }), "top-right");
  const geo = trackSegments(track);

  const addLayers = () => {
    const c = TRACK_COLORS[theme()];
    if (map.getSource("track")) return;
    map.addSource("track", { type: "geojson", data: geo });
    map.addLayer({ id: "track-glow", type: "line", source: "track", layout: { "line-cap": "round", "line-join": "round" },
      paint: { "line-color": ["match", ["get", "state"], "ok", c.ok, "over", c.over, "over2", c.over2, c.unknown],
        "line-width": 12, "line-opacity": theme() === "dark" ? 0.22 : 0.16, "line-blur": 6 } });
    map.addLayer({ id: "track-casing", type: "line", source: "track", layout: { "line-cap": "round", "line-join": "round" },
      paint: { "line-color": theme() === "dark" ? "#021941" : "#ffffff", "line-width": 6.5 } });
    map.addLayer({ id: "track-line", type: "line", source: "track", layout: { "line-cap": "round", "line-join": "round" },
      paint: { "line-color": ["match", ["get", "state"], "ok", c.ok, "over", c.over, "over2", c.over2, c.unknown],
        "line-width": 4 } });
  };
  map.on("style.load", addLayers);

  if (track.length) {
    const first = track[0], last = track[track.length - 1];
    new maplibregl.Marker({ element: h("div.pin.a", { title: t("trip.start") }) }).setLngLat([first[1], first[0]]).addTo(map);
    new maplibregl.Marker({ element: h("div.pin.b", { title: t("trip.finish") }) }).setLngLat([last[1], last[0]]).addTo(map);
  }
  for (const e of trip.events || []) {
    if (e.lat === null || e.lat === undefined || e.lon === null || e.lon === undefined) continue;
    const el = h(`button.ev-marker.${e.severity}`, { type: "button", "aria-label": kindName(e.kind) }, icon(KIND_ICON[e.kind] || "alert"));
    const details = [time(e.at)];
    if (e.speedKmh !== null && e.speedKmh !== undefined) details.push(`${num(e.speedKmh)} ${t("unit.kmh")}`);
    const pop = h("div.pop", h("b", kindName(e.kind)), h("span", `${t("sev." + e.severity)} · ${details.join(" · ")}`),
      eventDetail(e) ? h("span", eventDetail(e)) : null);
    const popup = new maplibregl.Popup({ offset: 16, closeButton: true, maxWidth: "260px" }).setDOMContent(pop);
    new maplibregl.Marker({ element: el }).setLngLat([e.lon, e.lat]).setPopup(popup).addTo(map);
  }

  const onTheme = () => {
    map.setStyle(STYLES[theme()]);
    const host = container.parentElement && container.parentElement.querySelector(".map-legend");
    if (host) host.replaceWith(legend());
  };
  document.addEventListener("rv:theme", onTheme);
  const obs = new MutationObserver(() => {
    if (!container.isConnected) { document.removeEventListener("rv:theme", onTheme); obs.disconnect(); map.remove(); }
  });
  obs.observe(document.body, { childList: true, subtree: true });
  return map;
}

/** Extra line for an event: the measured value against its limit, in the kind's unit. */
export function eventDetail(e) {
  if (e.value === null || e.value === undefined) return "";
  const unit = e.kind === "speeding" ? t("unit.kmh") : e.kind === "tailgating" ? t("unit.m")
    : e.kind === "harshBraking" || e.kind === "harshAcceleration" ? "m/s²" : "";
  const v = `${num(e.value, 1)}${unit ? " " + unit : ""}`;
  if (e.limit === null || e.limit === undefined) return v;
  return `${v} / ${num(e.limit, 1)}${unit ? " " + unit : ""}`;
}
