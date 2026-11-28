// Admin: the admin token is entered once (login form → httpOnly admin session cookie), then drivers with totals.

import { api, ApiError } from "../api.js";
import { href, langSwitch, render, themeToggle } from "../app.js";
import { t } from "../i18n.js";
import { ago, dateLong, h, icon, km, num } from "../ui.js";

export async function adminPage() {
  let data;
  try {
    data = await api("api/v1/admin/overview");
  } catch (e) {
    if (e instanceof ApiError && e.status === 401) return loginForm();
    throw e;
  }
  return overview(data);
}

function top() {
  return h("header.topbar.always",
    h("a.brand", { href: href("/admin") },
      h("img", { src: "static/img/logo.png", alt: "", width: 32, height: 32 }),
      h("div", h("div.brand-name", "RoadVis"), h("div.brand-sub", t("admin.title")))),
    h("div.prefs", langSwitch(), themeToggle()));
}

function loginForm() {
  const input = h("input.input#admin-token", { type: "password", autocomplete: "current-password", required: true });
  const err = h("p.err", { role: "alert" });
  const btn = h("button.btn.primary", { type: "submit" }, icon("lock"), t("admin.signIn"));
  const form = h("form", { novalidate: true },
    h("div.field", h("label", { for: "admin-token" }, t("admin.token")), input), err, btn);
  form.addEventListener("submit", async (ev) => {
    ev.preventDefault();
    err.textContent = "";
    btn.disabled = true;
    try {
      await api("api/v1/admin/login", { method: "POST", body: { token: input.value.trim() } });
      render();
    } catch (e) {
      err.textContent = e instanceof ApiError && e.status === 401 ? t("admin.wrong")
        : e instanceof ApiError && e.status === 429 ? t("login.limited") : t("common.error");
      btn.disabled = false;
    }
  });
  return h("div", top(),
    h("div.center-page", { style: { minHeight: "calc(100vh - 60px)" } },
      h("div.card.center-card.reveal",
        h("img.logo", { src: "static/img/logo.png", alt: "RoadVis" }),
        h("h1", t("admin.loginTitle")),
        h("p", t("admin.loginText")),
        form)));
}

function overview(data) {
  const logout = h("button.btn", { type: "button" }, icon("logout"), t("admin.logout"));
  logout.addEventListener("click", async () => {
    await api("api/v1/admin/logout", { method: "POST" }).catch(() => null);
    render();
  });
  const tot = data.totals;
  const tile = (key, value, ico) => h("article.card.kpi",
    h("div.kpi-top", h("span.kpi-label", t(key)), h("span.kpi-ico", icon(ico))), h("div.kpi-val", value));
  const rows = data.drivers.map((d) => h("tr",
    h("td", h("b", d.driverName), d.demo ? h("span.chip-demo", t("admin.demo")) : null),
    h("td", d.platforms.map((p) => t(`platform.${p}`)).join(", ") || "—"),
    h("td.r", num(d.tripCount)),
    h("td.r", km(d.distanceKm)),
    h("td.r", d.avgScore === null ? "—" : num(d.avgScore)),
    h("td.r", num(d.level)),
    h("td", d.lastTripAt ? ago(d.lastTripAt) : "—"),
    h("td", dateLong(d.createdAt))));
  const tr = data.training;
  const samples = Object.entries(tr.samples || {}).map(([k, v]) => `${k}: ${v}`).join(" · ") || "—";
  return h("div", top(),
    h("main.main", { style: { marginLeft: 0, maxWidth: "1240px", marginInline: "auto" } },
      h("div.page-head", h("div", h("h1", t("admin.title")), h("p.sub", t("admin.sub"))), logout),
      h("section.kpis.four",
        tile("admin.drivers", num(tot.drivers), "user"),
        tile("admin.active", num(tot.activeLast30Days), "zap"),
        tile("admin.trips", num(tot.trips), "route"),
        tile("admin.km", `${km(tot.distanceKm)} ${t("unit.km")}`, "road")),
      h("section.card",
        h("div.card-head", h("h2", t("admin.drivers"))),
        data.drivers.length ? h("div.tbl-wrap", h("table.tbl",
          h("thead", h("tr",
            h("th", t("admin.colName")), h("th", t("admin.colPlatform")), h("th.r", t("admin.colTrips")),
            h("th.r", t("admin.colKm")), h("th.r", t("admin.colAvg")), h("th.r", t("admin.colLevel")),
            h("th", t("admin.colLast")), h("th", t("admin.colCreated")))),
          h("tbody", rows)))
          : h("div.empty", icon("user"), h("b", t("admin.noDrivers")))),
      h("section.card", { style: { marginTop: "18px" } },
        h("div.card-head", h("h2", t("admin.training"))),
        h("div.list",
          h("div.list-item", h("div.li-ico", icon("sparkle")), h("div.li-main", h("b", tr.currentModel || "—"), h("span", t("admin.model")))),
          h("div.list-item", h("div.li-ico", icon("camera")), h("div.li-main", h("b", samples), h("span", t("admin.samples")))),
          h("div.list-item", h("div.li-ico", icon("clock")), h("div.li-main", h("b", tr.workerHeartbeat ? ago(tr.workerHeartbeat) : "—"), h("span", t("admin.worker"))))))));
}
