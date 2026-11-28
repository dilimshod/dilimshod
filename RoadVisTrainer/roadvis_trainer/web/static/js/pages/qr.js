// /qr opened in a normal browser (not scanned by the app): explain what to do.

import { href, langSwitch, themeToggle } from "../app.js";
import { t } from "../i18n.js";
import { h } from "../ui.js";

export function qrInfoPage() {
  return h("div.center-page",
    h("div.card.center-card.reveal",
      h("img.logo", { src: "static/img/logo.png", alt: "RoadVis" }),
      h("h1", t("qr.title")),
      h("p", t("qr.text")),
      h("ol.steps", [1, 2, 3, 4].map((i) => h("li", h("span.n", { "aria-hidden": "true" }, String(i)),
        h("div", h("b", t(`login.step${i}`)), h("span", t(`login.step${i}s`)))))),
      h("div", { style: { display: "flex", gap: "10px", justifyContent: "center", alignItems: "center", marginTop: "26px", flexWrap: "wrap" } },
        h("a.btn.primary", { href: href("/login") }, t("qr.home")), langSwitch(), themeToggle())));
}
