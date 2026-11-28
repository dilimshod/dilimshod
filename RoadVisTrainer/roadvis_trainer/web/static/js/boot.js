// Applies the saved theme and language before the first paint (no inline scripts: the CSP allows 'self' only).
(function () {
  var theme = "dark", lang = "uz";
  try {
    theme = localStorage.getItem("rv.theme") || "dark";
    lang = localStorage.getItem("rv.lang") || "uz";
  } catch (e) { /* storage blocked: defaults */ }
  if (theme !== "light" && theme !== "dark") theme = "dark";
  if (["uz", "ru", "en"].indexOf(lang) < 0) lang = "uz";
  document.documentElement.setAttribute("data-theme", theme);
  document.documentElement.setAttribute("lang", lang);
})();
