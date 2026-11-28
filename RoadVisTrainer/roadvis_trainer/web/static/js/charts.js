// Charts with the vendored Apache ECharts. Colours come from CSS tokens (validated palette, see app.css), so the
// light and dark themes each get their own selected steps. Thin marks, 2px lines, hairline grids, hover tooltips.

import { getLang, kindName, t } from "./i18n.js";
import { cssVar, dateShort, h, loadScript, num, pct, reducedMotion } from "./ui.js";

const live = new Set();   // {el, chart, draw}
let resizeObs;

export async function ensureECharts() {
  await loadScript("static/vendor/echarts/echarts.min.js");
  return window.echarts;
}

function tokens() {
  return {
    text: cssVar("--text"), text2: cssVar("--text-2"), text3: cssVar("--text-3"),
    surface: cssVar("--surface-solid"), line: cssVar("--line-strong"),
    grid: cssVar("--chart-grid"), axis: cssVar("--chart-axis"),
    s1: cssVar("--series-1"), s2: cssVar("--series-2"), bad: cssVar("--bad"),
    seq: [1, 2, 3, 4, 5].map((i) => cssVar(`--seq-${i}`)),
    heat0: cssVar("--heat-0"), heat1: cssVar("--heat-1"),
    font: getComputedStyle(document.body).fontFamily,
  };
}

function tooltipBase(k) {
  return {
    backgroundColor: k.surface, borderColor: k.line, borderWidth: 1, padding: [8, 12],
    textStyle: { color: k.text, fontFamily: k.font, fontSize: 12.5 },
    extraCssText: "border-radius:12px;box-shadow:0 14px 30px -12px rgba(0,0,0,.55);",
  };
}

function axisCommon(k) {
  return {
    axisLine: { lineStyle: { color: k.axis } }, axisTick: { show: false },
    axisLabel: { color: k.text2, fontFamily: k.font, fontSize: 11.5 },
    splitLine: { lineStyle: { color: k.grid, width: 1, type: "solid" } },
  };
}

/** Mounts a chart into ``el``; ``build(tokens)`` returns the ECharts option. Re-drawn on theme/language change. */
export async function mount(el, build) {
  const echarts = await ensureECharts();
  if (!el.isConnected) return null;
  const chart = echarts.init(el, null, { renderer: "svg" });
  const entry = { el, chart, draw: () => chart.setOption({ animation: !reducedMotion(), ...build(tokens()) }, true) };
  entry.draw();
  live.add(entry);
  if (!resizeObs) {
    resizeObs = new ResizeObserver((items) => {
      for (const it of items) for (const e of live) if (e.el === it.target) e.chart.resize();
    });
  }
  resizeObs.observe(el);
  return chart;
}

export function redrawAll() {
  for (const e of [...live]) {
    if (!e.el.isConnected) { disposeEntry(e); continue; }
    e.draw();
  }
}

function disposeEntry(e) {
  try { resizeObs && resizeObs.unobserve(e.el); e.chart.dispose(); } catch (err) { /* already gone */ }
  live.delete(e);
}

export function disposeAll() { for (const e of [...live]) disposeEntry(e); }

const dateFmt = () => ({ format: (d) => dateShort(d.toISOString()) });

// Score trend (one series: no legend box — the card title names it) ---------------------------------------------
export function scoreTrend(el, daily) {
  return mount(el, (k) => {
    const data = daily.map((d) => [d.date, d.avgScore]);
    const lo = Math.min(...daily.map((d) => d.avgScore)) - 5;
    const step = 100 - lo > 50 ? 20 : 10;
    const min = Math.max(0, Math.floor(lo / step) * step);
    const showDots = data.length <= 45;
    const last = data[data.length - 1];
    return {
      grid: { left: 36, right: 18, top: 16, bottom: 28 },
      tooltip: { ...tooltipBase(k), trigger: "axis",
        axisPointer: { type: "line", lineStyle: { color: k.axis, width: 1 } },
        formatter: (ps) => {
          const p = ps[0];
          const d = daily[p.dataIndex];
          return `<b>${dateFmt().format(new Date(d.date))}</b><br>${t("chart.score")}: <b>${num(d.avgScore)}</b>`
            + `<br>${t("chart.trips")}: ${d.trips} · ${num(d.km, 1)} ${t("unit.km")}`;
        } },
      xAxis: { type: "time", ...axisCommon(k), splitLine: { show: false },
        axisLabel: { ...axisCommon(k).axisLabel, hideOverlap: true, formatter: (v) => dateFmt().format(new Date(v)) } },
      yAxis: { type: "value", min, max: 100, interval: step, ...axisCommon(k),
        axisLine: { show: false } },
      series: [{
        type: "line", data, smooth: 0.25, showSymbol: showDots, symbol: "circle", symbolSize: 8,
        lineStyle: { width: 2, color: k.s1, cap: "round", join: "round" },
        itemStyle: { color: k.s1, borderColor: k.surface, borderWidth: 2 },
        areaStyle: { color: k.s1, opacity: 0.1 },
        emphasis: { scale: 1.4 },
        markPoint: last ? { symbol: "circle", symbolSize: 10, data: [{ coord: last, value: num(last[1]) }],
          itemStyle: { color: k.s1, borderColor: k.surface, borderWidth: 2 },
          label: { position: "top", distance: 8, color: k.text, fontWeight: 700, fontFamily: k.font } } : undefined,
      }],
    };
  });
}

// Events per 100 km (one series: horizontal bars, value at the tip) ---------------------------------------------
export function eventsBar(el, events) {
  const rows = events.filter((e) => !e.info && e.per100Km !== null).slice(0, 8).reverse();
  return mount(el, (k) => ({
    grid: { left: 8, right: 44, top: 6, bottom: 6, containLabel: true },
    tooltip: { ...tooltipBase(k), trigger: "item",
      formatter: (p) => {
        const e = rows[p.dataIndex];
        return `<b>${kindName(e.kind)}</b><br>${t("chart.per100")}: <b>${num(e.per100Km, 1)}</b><br>`
          + `${t("chart.count")}: ${e.count}${e.estimate ? `<br><span style="opacity:.7">${t("recs.estimate")}</span>` : ""}`;
      } },
    xAxis: { type: "value", ...axisCommon(k), axisLabel: { show: false }, splitLine: { show: false },
      axisLine: { show: false } },
    yAxis: { type: "category", data: rows.map((e) => kindName(e.kind)), ...axisCommon(k),
      axisLine: { show: false }, axisLabel: { ...axisCommon(k).axisLabel, color: k.text2, width: 150, overflow: "truncate" } },
    series: [{
      type: "bar", data: rows.map((e) => e.per100Km), barWidth: 14, barCategoryGap: "40%",
      itemStyle: { color: k.s2, borderRadius: [0, 4, 4, 0] },
      label: { show: true, position: "right", color: k.text, fontFamily: k.font, fontWeight: 700, fontSize: 12,
        formatter: (p) => num(p.value, 1) },
      emphasis: { itemStyle: { color: k.s2 } },
    }],
  }));
}

// Speed bands donut (ordinal → one-hue ramp; HTML legend with shares) -------------------------------------------
export function bandColors(n) {
  const seq = tokens().seq;
  if (n <= seq.length) {
    const pick = n === 1 ? [2] : n === 2 ? [1, 3] : n === 3 ? [0, 2, 4] : n === 4 ? [0, 1, 3, 4] : [0, 1, 2, 3, 4];
    return pick.map((i) => seq[i]);
  }
  return Array.from({ length: n }, (_, i) => seq[Math.round((i / (n - 1)) * (seq.length - 1))]);
}

export function bandsDonut(el, bands, centerText) {
  return mount(el, (k) => {
    const colors = bandColors(bands.length);
    return {
      tooltip: { ...tooltipBase(k), trigger: "item",
        formatter: (p) => `<b>${bands[p.dataIndex].band} ${t("unit.kmh")}</b><br>${t("chart.share")}: <b>${pct(bands[p.dataIndex].share)}</b>`
          + `<br>${t("chart.time")}: ${Math.round(bands[p.dataIndex].seconds / 60)} ${t("unit.min")}` },
      title: centerText ? { text: centerText[0], subtext: centerText[1], left: "center", top: "38%",
        textStyle: { color: k.text, fontFamily: cssVar("--display") || k.font, fontSize: 22, fontWeight: 600 },
        subtextStyle: { color: k.text2, fontFamily: k.font, fontSize: 12 }, itemGap: 4 } : undefined,
      series: [{
        type: "pie", radius: ["60%", "86%"], center: ["50%", "50%"], avoidLabelOverlap: true, padAngle: 1.5,
        itemStyle: { borderRadius: 4, borderColor: k.surface, borderWidth: 2 },
        label: { show: false }, labelLine: { show: false },
        emphasis: { scale: true, scaleSize: 4 },
        data: bands.map((b, i) => ({ value: b.seconds, name: b.band, itemStyle: { color: colors[i] } })),
      }],
    };
  });
}

export function bandsLegend(bands) {
  const colors = bandColors(bands.length);
  return h("div.legend", { style: { flexDirection: "column", gap: "8px" } }, bands.map((b, i) =>
    h("span", { style: { justifyContent: "space-between", width: "100%" } },
      h("span", h("i", { style: { background: colors[i] } }), `${b.band} ${t("unit.kmh")}`),
      h("b.num", { style: { color: "var(--text)" } }, pct(b.share, 0)))));
}

// Weekly heatmap (sequential one hue; all 168 cells drawn so the grid reads) ------------------------------------
export function heatmap(el, cells) {
  return mount(el, (k) => {
    const map = new Map(cells.map((c) => [`${c.weekday}-${c.hour}`, c]));
    const data = [];
    let max = 0;
    for (let wd = 0; wd < 7; wd++) {
      for (let hr = 0; hr < 24; hr++) {
        const c = map.get(`${wd}-${hr}`);
        const v = c ? c.km : 0;
        max = Math.max(max, v);
        data.push([hr, 6 - wd, v, c ? c.trips : 0]);
      }
    }
    const wd = t("wd");
    return {
      grid: { left: 34, right: 8, top: 6, bottom: 46 },
      tooltip: { ...tooltipBase(k), trigger: "item",
        formatter: (p) => `<b>${wd[6 - p.value[1]]}, ${String(p.value[0]).padStart(2, "0")}:00</b><br>`
          + `${num(p.value[2], 1)} ${t("unit.km")} · ${t("chart.trips")}: ${p.value[3]}` },
      xAxis: { type: "category", data: Array.from({ length: 24 }, (_, i) => i), ...axisCommon(k),
        axisLine: { show: false }, splitLine: { show: false },
        axisLabel: { ...axisCommon(k).axisLabel, interval: 2, formatter: (v) => String(v).padStart(2, "0") } },
      yAxis: { type: "category", data: [...wd].reverse(), ...axisCommon(k), axisLine: { show: false },
        splitLine: { show: false } },
      visualMap: { min: 0, max: Math.max(1, max), calculable: false, orient: "horizontal", left: "center", bottom: 0,
        itemWidth: 10, itemHeight: 120, text: [num(Math.max(1, max), 0) + " " + t("unit.km"), "0"],
        textStyle: { color: k.text2, fontFamily: k.font, fontSize: 11 },
        inRange: { color: [k.heat0, k.heat1] }, dimension: 2 },
      series: [{
        type: "heatmap", data, itemStyle: { borderColor: k.surface, borderWidth: 2, borderRadius: 3 },
        emphasis: { itemStyle: { borderColor: k.text, borderWidth: 1 } },
      }],
    };
  });
}

// Trip: speed and limit over time (one axis, km/h) -------------------------------------------------------------
export function speedChart(el, track) {
  const rows = track.filter((r) => r[3] !== null && r[3] !== undefined);
  return mount(el, (k) => {
    const speed = rows.map((r) => [r[2] / 60, r[3]]);
    const limit = rows.map((r) => [r[2] / 60, r[4] ?? null]);
    const over = rows.map((r) => [r[2] / 60, r[4] !== null && r[4] !== undefined && r[3] > r[4] ? r[3] : null]);
    return {
      grid: { left: 40, right: 16, top: 14, bottom: 30 },
      tooltip: { ...tooltipBase(k), trigger: "axis",
        axisPointer: { type: "line", lineStyle: { color: k.axis, width: 1 } },
        formatter: (ps) => {
          const i = ps[0].dataIndex;
          const r = rows[i];
          const m = Math.floor(r[2] / 60), s = Math.round(r[2] % 60);
          let out = `<b>${m}:${String(s).padStart(2, "0")}</b><br>${t("trip.speed")}: <b>${num(r[3])}</b> ${t("unit.kmh")}`;
          if (r[4] !== null && r[4] !== undefined) out += `<br>${t("trip.limit")}: ${num(r[4])} ${t("unit.kmh")}`;
          return out;
        } },
      xAxis: { type: "value", ...axisCommon(k), splitLine: { show: false }, min: 0,
        max: speed.length ? Math.ceil(speed[speed.length - 1][0]) : 1,
        axisLabel: { ...axisCommon(k).axisLabel, formatter: (v) => `${Math.round(v)} ${t("unit.min")}` } },
      yAxis: { type: "value", min: 0, ...axisCommon(k), axisLine: { show: false } },
      series: [
        { name: t("trip.limit"), type: "line", step: "end", data: limit, showSymbol: false, connectNulls: false,
          lineStyle: { width: 1.5, color: k.text3 }, itemStyle: { color: k.text3 }, z: 1 },
        { name: t("trip.speed"), type: "line", data: speed, showSymbol: false, sampling: "lttb",
          lineStyle: { width: 2, color: k.s1 }, itemStyle: { color: k.s1 }, areaStyle: { color: k.s1, opacity: 0.1 }, z: 2 },
        { name: t("trip.over"), type: "line", data: over, showSymbol: false, connectNulls: false,
          lineStyle: { width: 2.5, color: k.bad }, itemStyle: { color: k.bad }, z: 3 },
      ],
    };
  });
}

export function speedLegend() {
  return h("div.legend",
    h("span", h("i.line", { style: { background: "var(--series-1)" } }), t("trip.speed")),
    h("span", h("i.line", { style: { background: "var(--text-3)" } }), t("trip.limit")),
    h("span", h("i.line", { style: { background: "var(--bad)" } }), t("trip.over")));
}

/** A data table alternative for a chart (accessibility). */
export function tableToggle(container, headers, rows) {
  const tableHost = h("div");
  let open = false;
  const btn = h("button.table-toggle", { type: "button", "aria-expanded": "false" }, t("chart.table"));
  btn.addEventListener("click", () => {
    open = !open;
    btn.textContent = open ? t("chart.hideTable") : t("chart.table");
    btn.setAttribute("aria-expanded", String(open));
    tableHost.replaceChildren();
    if (open) {
      tableHost.append(h("table.mini-table",
        h("thead", h("tr", headers.map((x, i) => h(i ? "th.r" : "th", x)))),
        h("tbody", rows.map((r) => h("tr", r.map((c, i) => h(i ? "td.r" : "td", c)))))));
    }
  });
  container.append(tableHost);
  return btn;
}
