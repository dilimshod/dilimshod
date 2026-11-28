# Third-party components of the web dashboard

The driver-cabinet dashboard (`roadvis_trainer/web/`) vendors these files, so the site loads no third-party CDN.
They were downloaded unmodified from jsDelivr (npm packages, exact versions). Each folder holds the licence text.

| Component | Version | Files | Licence | Source |
|---|---|---|---|---|
| MapLibre GL JS | 5.24.0 | `static/vendor/maplibre/maplibre-gl.js`, `maplibre-gl.css` | BSD-3-Clause (`LICENSE.txt`) | https://cdn.jsdelivr.net/npm/maplibre-gl@5.24.0/dist/ |
| Apache ECharts | 5.6.0 | `static/vendor/echarts/echarts.min.js` | Apache-2.0 (`LICENSE`) | https://cdn.jsdelivr.net/npm/echarts@5.6.0/dist/ |
| qrcode-generator (Kazuhiko Arase) | 1.5.2 | `static/vendor/qrcode/qrcode.js` | MIT (`LICENSE`) | https://cdn.jsdelivr.net/npm/qrcode-generator@1.5.2/qrcode.js |
| Manrope (variable, via Fontsource) | 5.2.8 | `static/fonts/manrope-*.woff2` | SIL OFL 1.1 (`fonts/OFL-manrope.txt`) | https://cdn.jsdelivr.net/npm/@fontsource-variable/manrope@5.2.8/files/ |
| Unbounded (variable, via Fontsource) | 5.2.8 | `static/fonts/unbounded-*.woff2` | SIL OFL 1.1 (`fonts/OFL-unbounded.txt`) | https://cdn.jsdelivr.net/npm/@fontsource-variable/unbounded@5.2.8/files/ |

SHA-256 of the vendored scripts:

```
45a9b07a9189ce56054c620a947ccf41e291e58c95e9b61533b740aaa65ee5cb  maplibre-gl.js
ab1e70d59ec40465bae7e7030da2f3ccf28133fd502e62bd598eefbadfd7a732  maplibre-gl.css
bf4a223524e40b77c304bec67e1222cf551f14880cf42c69dc046558e11c07b1  echarts.min.js
18ae399f81182bc9de916e9c77b195df20cc58d6f2d55a62b085a299f1bf1780  qrcode.js
```

Map data (loaded at runtime, not vendored): vector tiles and styles from **OpenFreeMap**
(`https://tiles.openfreemap.org/styles/dark` and `/styles/positron`), © OpenMapTiles, data © OpenStreetMap
contributors (ODbL). The attribution is shown on the map.

The logo and app icon (`static/img/`) are the RoadVis app's own assets
(`RoadVis/RoadVis/Assets.xcassets/SplashLogo.imageset`, `AppIcon.appiconset`).

To update a library: download the new exact version into the same folder, update this table and the hashes, and
check the trip map and charts in both themes.
