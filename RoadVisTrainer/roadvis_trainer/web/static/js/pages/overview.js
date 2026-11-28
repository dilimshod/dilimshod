// Overview: level gauge, KPI tiles, score trend, events per 100 km, speed bands, weekly heatmap, badges, advice.

import { api } from "../api.js";
import { state } from "../app.js";
import { bandsDonut, bandsLegend, disposeAll, eventsBar, heatmap, scoreTrend, tableToggle } from "../charts.js";
import { getLang, kindName, t } from "../i18n.js";
import { BADGE_ICON, dateLong, duration, h, icon, km, num, pct, reducedMotion, svg } from "../ui.js";

const REC_ICON = {
  keepDistance: "gap", speed: "speed", anticipation: "brake", laneDiscipline: "lane", smoothAcceleration: "zap",
  collisionRisk: "alert", pedestrianNotYielded: "footprints", redLightRunning: "traffic", stopSignIgnored: "stop",
  keepItUp: "star",
};

export async function overviewPage(view) {
  disposeAll();
  view.replaceChildren(skeleton());
  const days = state.days;
  const [sum, charts] = await Promise.all([
    api(`api/v1/dashboard/summary?days=${days}`), api(`api/v1/dashboard/charts?days=${days}`)]);
  state.me = { ...state.me, driverName: sum.driver.driverName, points: sum.level.points, level: sum.level.level };

  const periodSeg = h("div.seg", { role: "group", "aria-label": t("period.label") },
    [30, 90, 365].map((d) => h("button", { type: "button", "aria-pressed": String(d === days),
      onclick: async () => {
        if (d === state.days) return;
        state.days = d;
        try { localStorage.setItem("rv.days", String(d)); } catch (e) { /* ignore */ }
        await overviewPage(view);
      } }, t(`period.${d}`))));

  const head = h("div.page-head",
    h("div", h("h1", t("ov.hello", { name: sum.driver.driverName })),
      h("p.sub", days === 365 ? t("ov.subYear") : t("ov.sub", { d: days }))),
    periodSeg);

  const empty = sum.period.trips === 0;
  const grid = h("div.grid.ov-grid");
  const cards = {
    trend: card("chart.scoreTrend", "chart.scoreTrendHint", "span-8"),
    bands: card("chart.bands", "chart.bandsHint", "span-4"),
    events: card("chart.events", "chart.eventsHint", "span-6"),
    heat: card("chart.heatmap", "chart.heatmapHint", "span-6"),
    recs: card("recs.title", "recs.hint", "span-7"),
    badges: card("badges.title", null, "span-5"),
  };
  grid.append(...Object.values(cards).map((c) => c.el));

  view.replaceChildren(
    head,
    sum.driver.demo ? h("div.banner", icon("info"), t("demo.banner")) : null,
    h("section.hero", gaugeCard(sum.level), kpis(sum)),
    grid);

  // Charts (lazy ECharts) ---------------------------------------------------------------------------------------
  if (empty) {
    for (const k of ["trend", "bands", "events", "heat"]) cards[k].body.append(emptyState());
  } else {
    const trendEl = h("div.chart.tall");
    cards.trend.body.append(trendEl);
    cards.trend.tools.append(tableToggle(cards.trend.body, [t("chart.date"), t("chart.score"), t("chart.trips"), t("chart.km")],
      charts.daily.map((d) => [d.date, num(d.avgScore), d.trips, num(d.km, 1)])));
    scoreTrend(trendEl, charts.daily);

    if (charts.speedBands.length) {
      const donutEl = h("div.chart.short");
      cards.bands.body.append(donutEl, bandsLegend(charts.speedBands));
      bandsDonut(donutEl, charts.speedBands, sum.period.avgSpeedKmh ? [num(sum.period.avgSpeedKmh), t("unit.kmh")] : null);
    } else {
      cards.bands.body.append(emptyState());
    }

    const evRows = charts.events.filter((e) => !e.info && e.per100Km !== null);
    if (evRows.length) {
      const evEl = h("div.chart", { style: { height: `${Math.max(150, Math.min(8, evRows.length) * 34 + 20)}px` } });
      cards.events.body.append(evEl);
      cards.events.tools.append(tableToggle(cards.events.body, [t("chart.kind"), t("chart.per100"), t("chart.count")],
        evRows.map((e) => [kindName(e.kind), num(e.per100Km, 1), e.count])));
      eventsBar(evEl, charts.events);
    } else {
      cards.events.body.append(h("div.empty", icon("shieldCheck"), h("b", t("chart.noEvents"))));
    }

    const heatEl = h("div.chart", { style: { height: "250px" } });
    cards.heat.body.append(heatEl);
    heatmap(heatEl, charts.heatmap);
  }

  // Recommendations ----------------------------------------------------------------------------------------------
  if (sum.recommendations.length) {
    const lang = getLang();
    cards.recs.body.append(h("div.recs", sum.recommendations.map((r) => h(`article.rec.${r.level}`,
      h("div.rico", icon(REC_ICON[r.id] || "info")),
      h("div",
        h("h3", r.title[lang] || r.title.uz),
        h("p", r.text[lang] || r.text.uz),
        h("div.meta",
          h(`span.tag.${r.level}`, t(`recs.${r.level}`)),
          r.estimate ? h("span.tag", icon("camera"), t("recs.estimate")) : null,
          metricTag(r.metric)))))));
  } else {
    cards.recs.body.append(h("div.empty", icon("info"), h("b", t("recs.empty"))));
  }

  // Badges -------------------------------------------------------------------------------------------------------
  const earned = sum.badges.filter((b) => b.earned).length;
  cards.badges.hint.textContent = t("badges.count", { n: earned, m: sum.badges.length });
  cards.badges.body.append(h("div.badges", sum.badges.map(badgeTile)));
}

function card(titleKey, hintKey, span) {
  const hint = h("span.hint", hintKey ? t(hintKey) : "");
  const tools = h("div", { style: { display: "flex", gap: "12px", alignItems: "baseline" } }, hint);
  const body = h("div");
  const el = h(`section.card.${span}`, h("div.card-head", h("h2", t(titleKey)), tools), body);
  return { el, body, hint, tools };
}

function emptyState() {
  return h("div.empty", icon("route"), h("b", t("chart.noData")), h("span", t("chart.noDataHint")));
}

function metricTag(m) {
  if (!m || m.unit === "count") return null;
  let v;
  if (m.unit === "share") v = pct(m.value, 1);
  else if (m.unit === "per100km") v = `${num(m.value, 1)} / 100 ${t("unit.km")}`;
  else v = num(m.value);
  return h("span.tag.num", v);
}

// Gauge: a 270° instrument dial with tick marks; the orange dot is the logo's dot ---------------------------------
function gaugeCard(level) {
  const cx = 120, cy = 118, r = 96, start = 135, sweep = 270;
  const p = Math.max(0, Math.min(1, level.progress));
  const polar = (deg, rad) => [cx + rad * Math.cos((deg * Math.PI) / 180), cy + rad * Math.sin((deg * Math.PI) / 180)];
  const arcPath = (rad) => {
    const [x0, y0] = polar(start, rad), [x1, y1] = polar(start + sweep, rad);
    return `M${x0},${y0} A${rad},${rad} 0 1 1 ${x1},${y1}`;
  };
  const len = (2 * Math.PI * r * sweep) / 360;
  const s = svg("svg", { viewBox: "0 0 240 210", "aria-hidden": "true" });
  const defs = svg("defs");
  const grad = svg("linearGradient", { id: "gaugeGrad", x1: "0", y1: "1", x2: "1", y2: "0" },
    svg("stop", { offset: "0", "stop-color": "#0a6e8a" }), svg("stop", { offset: "1", "stop-color": "#19e3ec" }));
  defs.append(grad);
  s.append(defs);
  for (let i = 0; i <= 36; i++) {
    const deg = start + (sweep * i) / 36;
    const major = i % 6 === 0;
    const [x0, y0] = polar(deg, r + 13), [x1, y1] = polar(deg, r + (major ? 21 : 17));
    s.append(svg("line", { x1: x0, y1: y0, x2: x1, y2: y1, class: "tick" + (major ? " major" : ""), "stroke-width": major ? 2 : 1.2, "stroke-linecap": "round" }));
  }
  s.append(svg("path", { d: arcPath(r), class: "track", fill: "none", "stroke-width": 14, "stroke-linecap": "round" }));
  const arc = svg("path", { d: arcPath(r), class: "arc", fill: "none", "stroke-width": 14, "stroke-linecap": "round",
    "stroke-dasharray": `${len} ${len}`, "stroke-dashoffset": String(len) });
  s.append(arc);
  const [dx, dy] = polar(start + sweep * p, r);
  const dot = svg("circle", { cx: dx, cy: dy, r: 8.5, class: "needle-dot", stroke: "var(--surface-solid)", "stroke-width": 3, opacity: "0" });
  s.append(dot);
  const target = len * (1 - Math.max(p, 0.004));
  if (reducedMotion()) {
    arc.setAttribute("stroke-dashoffset", String(target));
    dot.setAttribute("opacity", "1");
  } else {
    arc.style.transition = "stroke-dashoffset 1.3s cubic-bezier(.2,.7,.2,1)";
    dot.style.transition = "opacity .4s ease 1.1s";
    requestAnimationFrame(() => requestAnimationFrame(() => {
      arc.setAttribute("stroke-dashoffset", String(target));
      dot.setAttribute("opacity", "1");
    }));
  }
  const left = level.nextLevelPoints - level.points;
  return h("section.card.gauge-card", { "aria-label": t("ov.gaugeLabel", { level: level.level, points: level.points, left }) },
    h("div.gauge", s,
      h("div.gauge-center",
        h("div.lbl", t("ov.level")),
        h("div.big", String(level.level)),
        h("div.pts", t("ov.points", { n: num(level.points) })))),
    h("div.gauge-foot",
      h("span", t("ov.nextLevel"), " ", h("b", num(level.nextLevelPoints))),
      h("span", t("ov.toNext", { n: num(left) }))));
}

// KPI tiles --------------------------------------------------------------------------------------------------------
function kpis(sum) {
  const cur = sum.period, prev = sum.previous, hasPrev = prev.trips > 0;
  const relDelta = (a, b) => (hasPrev && b ? (a - b) / b : null);
  return h("section.kpis",
    kpi("kpi.distance", "road", km(cur.distanceKm), t("unit.km"),
      deltaChip(relDelta(cur.distanceKm, prev.distanceKm), "neutral", (v) => pct(Math.abs(v), 0)),
      t("kpi.driving", { t: duration(cur.movingSeconds) })),
    kpi("kpi.trips", "route", num(cur.trips), "",
      deltaChip(relDelta(cur.trips, prev.trips), "neutral", (v) => pct(Math.abs(v), 0)),
      cur.cleanTripShare !== null ? t("kpi.clean", { p: pct(cur.cleanTripShare, 0) }) : ""),
    kpi("kpi.score", "shieldCheck", cur.avgScore === null ? "—" : num(cur.avgScore), cur.avgScore === null ? "" : "/ 100",
      deltaChip(hasPrev && cur.avgScore !== null && prev.avgScore !== null ? cur.avgScore - prev.avgScore : null, "up",
        (v) => num(Math.abs(v), 1)),
      cur.eventsPer100Km !== null ? t("kpi.per100", { v: num(cur.eventsPer100Km, 1) }) : ""),
    kpi("kpi.overLimit", "speed", cur.overLimitShare === null ? "—" : pct(cur.overLimitShare, 1), "",
      deltaChip(hasPrev && cur.overLimitShare !== null && prev.overLimitShare !== null ? (cur.overLimitShare - prev.overLimitShare) * 100 : null,
        "down", (v) => `${num(Math.abs(v), 1)} p.p.`),
      cur.maxSpeedKmh ? t("kpi.maxSpeed", { v: `${num(cur.maxSpeedKmh)} ${t("unit.kmh")}` }) : ""));
}

function kpi(labelKey, ico, value, unit, delta, foot) {
  return h("article.card.kpi",
    h("div.kpi-top", h("span.kpi-label", t(labelKey)), h("span.kpi-ico", icon(ico))),
    h("div.kpi-val", value, unit ? h("small", unit) : null),
    h("div.kpi-foot", delta, foot ? h("span", foot) : null));
}

/** Delta chip: direction arrow + magnitude; colour by whether this direction is good (``good``: up|down|neutral). */
function deltaChip(v, good, fmtAbs) {
  if (v === null || v === undefined || Number.isNaN(v)) return h("span.delta.flat", { title: t("kpi.noPrev") }, "—");
  const dir = Math.abs(v) < 1e-9 ? "flat" : v > 0 ? "up" : "down";
  let cls = "flat";
  if (dir !== "flat" && good !== "neutral") cls = (dir === good) ? "up" : "down";
  return h(`span.delta.${cls}`, { title: t("kpi.vsPrev") }, icon(dir === "up" ? "up" : dir === "down" ? "down" : "flat"),
    h("span.sr-only", dir), fmtAbs(v));
}

function badgeTile(b) {
  const medal = h("div.medal");
  if (!b.earned) {
    const c = 2 * Math.PI * 25;
    const ring = svg("svg", { class: "ring", viewBox: "0 0 54 54", "aria-hidden": "true" },
      svg("circle", { cx: 27, cy: 27, r: 25, fill: "none", stroke: "var(--line-strong)", "stroke-width": 2 }),
      svg("circle", { cx: 27, cy: 27, r: 25, fill: "none", stroke: "var(--cyan)", "stroke-width": 2.5, "stroke-linecap": "round",
        "stroke-dasharray": `${c * b.progress} ${c}` }));
    medal.append(ring);
  }
  medal.append(icon(BADGE_ICON[b.id] || "award", "ico"));
  const tip = b.earned ? t("badges.earnedOn", { date: dateLong(b.earnedAt) }) : t("badges.progress", { p: pct(b.progress, 0) });
  return h(`div.badge${b.earned ? ".earned" : ""}`, { title: tip },
    medal, h("div.bname", t(`badge.${b.id}`)), h("div.bdesc", b.earned ? tip : t(`badgeDesc.${b.id}`)),
    h("span.sr-only", tip));
}

function skeleton() {
  return h("div",
    h("div.skel", { style: { height: "38px", width: "min(320px,70%)", marginBottom: "26px" } }),
    h("div.hero", h("div.skel", { style: { height: "330px", borderRadius: "22px" } }),
      h("div.kpis", [1, 2, 3, 4].map(() => h("div.skel", { style: { height: "150px", borderRadius: "22px" } })))),
    h("div.skel", { style: { height: "320px", borderRadius: "22px" } }));
}
