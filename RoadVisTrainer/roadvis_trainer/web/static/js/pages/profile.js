// Profile: rename, devices, website sessions, log out (everywhere), delete my data.

import { api } from "../api.js";
import { navigate, resetSession, state } from "../app.js";
import { t } from "../i18n.js";
import { ago, dateLong, h, icon, initials, toast } from "../ui.js";

export async function profilePage(view) {
  const [me, dev] = await Promise.all([api("api/v1/me"), api("api/v1/me/devices")]);
  state.me = me;

  // Name
  const input = h("input.input#driver-name", { value: me.driverName, maxlength: "60", autocomplete: "nickname", required: true });
  const err = h("p.err", { role: "alert" });
  const save = h("button.btn.primary", { type: "submit" }, t("profile.save"));
  const form = h("form.row", { novalidate: true },
    h("div.field", h("label", { for: "driver-name" }, t("profile.name")), input), save);
  form.addEventListener("submit", async (ev) => {
    ev.preventDefault();
    const name = input.value.trim();
    err.textContent = "";
    if (!name) { err.textContent = t("profile.nameEmpty"); input.focus(); return; }
    save.disabled = true;
    try {
      state.me = await api("api/v1/me", { method: "PATCH", body: { driverName: name } });
      toast(t("profile.saved"));
      const chip = document.querySelector(".driver-chip .name");
      if (chip) chip.textContent = state.me.driverName;
      const av = document.querySelector(".driver-chip .avatar");
      if (av) av.textContent = initials(state.me.driverName);
      hello.textContent = state.me.driverName;
    } catch (e) {
      err.textContent = t("common.error");
    } finally {
      save.disabled = false;
    }
  });

  const hello = h("span", me.driverName);
  const idCard = h("section.card",
    h("div", { style: { display: "flex", gap: "16px", alignItems: "center", marginBottom: "20px" } },
      h("div.avatar", { style: { width: "56px", height: "56px", fontSize: "19px" } }, initials(me.driverName)),
      h("div", h("div", { style: { fontWeight: 800, fontSize: "18px" } }, hello),
        h("div.faint", { style: { fontSize: "13.5px" } }, t("profile.since", { date: dateLong(me.createdAt) }), " · ",
          t("level.n", { n: me.level })))),
    form, err);

  // Devices
  const devCard = h("section.card",
    h("div.card-head", h("h2", t("profile.devices")), h("span.hint", t("profile.devicesHint"))),
    h("div.list", dev.devices.map((d) => h("div.list-item",
      h("div.li-ico", icon("phone")),
      h("div.li-main", h("b", d.name || t(`platform.${d.platform || "unknown"}`)),
        h("span", [t(`platform.${d.platform || "unknown"}`), d.appVersion ? `v${d.appVersion}` : null,
          t("profile.lastUsed", { t: ago(d.lastUsedAt) })].filter(Boolean).join(" · ")))))));

  // Sessions
  const logout = h("button.btn", { type: "button" }, icon("logout"), t("profile.logout"));
  logout.addEventListener("click", async () => {
    await api("api/v1/auth/logout", { method: "POST" }).catch(() => null);
    resetSession(null);
    navigate("/login", { replace: true });
  });
  const logoutAll = h("button.btn", { type: "button" }, icon("logout"), t("profile.logoutAll"));
  logoutAll.addEventListener("click", async () => {
    logoutAll.disabled = true;
    try {
      await api("api/v1/auth/logout-all", { method: "POST" });
      toast(t("profile.loggedOutAll"));
      resetSession(null);
      navigate("/login", { replace: true });
    } catch (e) {
      logoutAll.disabled = false;
      toast(t("common.error"));
    }
  });
  const sesCard = h("section.card",
    h("div.card-head", h("h2", t("profile.sessions"))),
    h("div.list", dev.sessions.map((s) => h("div.list-item",
      h("div.li-ico", icon("monitor")),
      h("div.li-main", h("b", browserName(s.userAgent)), h("span", t("profile.lastUsed", { t: ago(s.lastSeenAt) }))),
      s.current ? h("span.pill-cur", t("profile.current")) : null))),
    h("p.faint", { style: { fontSize: "13px", margin: "14px 0" } }, t("profile.logoutAllHint")),
    h("div", { style: { display: "flex", gap: "10px", flexWrap: "wrap" } }, logout, logoutAll));

  // Danger zone
  const delBtn = h("button.btn.danger", { type: "button" }, icon("trash"), t("profile.deleteBtn"));
  delBtn.addEventListener("click", () => confirmDeleteAll(me.tripCount));
  const dangerCard = h("section.card.danger-zone",
    h("div.card-head", h("h2", t("profile.danger"))),
    h("p.muted", { style: { marginBottom: "16px", maxWidth: "62ch" } }, t("profile.dangerText")),
    delBtn);

  view.replaceChildren(
    h("div.page-head", h("div", h("h1", t("profile.title")), h("p.sub", t("profile.sub")))),
    h("div.stack",
      h("div.prof-grid", idCard, devCard),
      sesCard,
      dangerCard));
}

function browserName(ua) {
  ua = ua || "";
  const b = /Edg\//.test(ua) ? "Edge" : /OPR\//.test(ua) ? "Opera" : /Firefox\//.test(ua) ? "Firefox"
    : /Chrome\//.test(ua) ? "Chrome" : /Safari\//.test(ua) ? "Safari" : "Browser";
  const os = /iPhone|iPad/.test(ua) ? "iOS" : /Android/.test(ua) ? "Android" : /Mac OS X/.test(ua) ? "macOS"
    : /Windows/.test(ua) ? "Windows" : /Linux/.test(ua) ? "Linux" : "";
  return os ? `${b}, ${os}` : b;
}

function confirmDeleteAll(tripCount) {
  const check = h("input", { type: "checkbox", id: "confirm-del" });
  const ok = h("button.btn.danger.solid", { type: "button", disabled: true }, icon("trash"), t("profile.deleteBtn"));
  check.addEventListener("change", () => { ok.disabled = !check.checked; });
  const dlg = h("dialog", { "aria-labelledby": "dlg-title" },
    h("h2#dlg-title", t("profile.deleteTitle")),
    h("p", t("profile.dangerText"), " ", t("profile.deleteAppHint")),
    h("label.check", { for: "confirm-del" }, check, h("span", t("profile.deleteCheck", { n: tripCount }))));
  const cancel = h("button.btn", { type: "button", onclick: () => dlg.close() }, t("common.cancel"));
  ok.addEventListener("click", async () => {
    ok.disabled = true;
    try {
      await api("api/v1/me", { method: "DELETE" });
      dlg.close();
      resetSession(null);
      toast(t("profile.deleted"));
      navigate("/login", { replace: true });
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
