package uz.roadvis.app.navigation

import uz.roadvis.app.l10n.AppLanguage
import uz.roadvis.app.l10n.L
import uz.roadvis.app.l10n.LocalizationManager
import uz.roadvis.core.CongestionLevel
import uz.roadvis.core.RVFormat
import uz.roadvis.core.RVLang
import uz.roadvis.core.RoadIncidentKind
import uz.roadvis.core.RoadSegmentInfo
import uz.roadvis.core.RouteFeatureKind
import uz.roadvis.core.RouteSource
import uz.roadvis.core.RouteTimelineText
import uz.roadvis.core.SignalWaitEstimate
import uz.roadvis.core.TrafficAssessment
import uz.roadvis.core.WeatherSnapshot
import uz.roadvis.core.decimal
import uz.roadvis.core.distance
import uz.roadvis.core.duration
import uz.roadvis.core.spokenDistance
import uz.roadvis.core.unitKmh
import java.util.Locale
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * App-language texts for core values (port of iOS `CoreNames+L10n.swift` / `L10n+Core.swift`). The core keeps
 * Russian `displayName`s; the UI shows these localized names. Android-only strings that are not in the generated
 * tables live in [fallback], keyed by the app language.
 */
object NavText {
    val lang: RVLang
        get() = when (LocalizationManager.language) {
            AppLanguage.UZ -> RVLang.UZ
            AppLanguage.RU -> RVLang.RU
            AppLanguage.EN -> RVLang.EN
        }

    fun distance(m: Double): String = RVFormat.distance(m, lang)
    fun duration(s: Double): String = RVFormat.duration(s, lang)
    fun spokenDistance(m: Double): String = RVFormat.spokenDistance(m, lang)
    val kmh: String get() = RVFormat.unitKmh(lang)
    fun clock(epochMs: Long): String = RVFormat.clock(java.util.Date(epochMs))

    /** "3 маршрута" / "3 routes" with the generated unit tables (`unit.<name>.one|few|many`). */
    fun quantity(n: Int, unit: String): String {
        val one = L("unit.$unit.one"); val few = L("unit.$unit.few"); val many = L("unit.$unit.many")
        if (lang == RVLang.RU) return "$n " + RVFormat.plural(n, one, few, many)
        return "$n " + if (n == 1) one else many
    }

    fun fractionQuantity(value: Double, unit: String): String {
        val word = if (lang == RVLang.RU) L("unit.$unit.few") else L("unit.$unit.many")
        return RVFormat.decimal(value, 1, lang) + " " + word
    }

    /** "600 метров", "1,5 километра", "12 километров" (iOS `NavigationService.spokenDistance`). */
    fun spokenQuantityDistance(meters: Double): String {
        val m = max(0.0, if (meters.isFinite()) meters else 0.0)
        if (m < 975) return quantity(max(50, ((m / 50).roundToInt()) * 50), "meter")
        if (m < 9_950) {
            val km = (m / 100).roundToInt() / 10.0
            if (km == Math.rint(km)) return quantity(km.toInt(), "km")
            return fractionQuantity(km, "km")
        }
        return quantity((m / 1000).roundToInt(), "km")
    }

    /** "1 минуту", "25 минут", "1 час 5 минут". */
    fun spokenDuration(seconds: Double): String {
        val total = max(1, ((if (seconds.isFinite()) seconds else 0.0) / 60).roundToInt())
        fun minutes(n: Int) = quantity(n, "minuteAcc")
        if (total < 60) return minutes(total)
        val hours = total / 60; val rest = total % 60
        val h = quantity(hours, "hour")
        return if (rest == 0) h else "$h ${minutes(rest)}"
    }

    // Core enum names

    fun feature(kind: RouteFeatureKind) = L("feature.${kind.raw}")
    fun incident(kind: RoadIncidentKind) = L("incident.kind.${kind.raw}")
    fun congestion(level: CongestionLevel) = L("congestion.${level.raw}")

    fun traffic(t: TrafficAssessment): String {
        val delay = t.delaySeconds
        if (t.level == CongestionLevel.FREE || delay < 60) return L("traffic.summary.short", congestion(t.level))
        return L("traffic.summary.delay", congestion(t.level), duration(delay))
    }

    fun signalSource(source: SignalWaitEstimate.Source): String = when (source) {
        SignalWaitEstimate.Source.LEARNED -> L("signal.src.learned")
        SignalWaitEstimate.Source.BLENDED -> L("signal.src.blended")
        SignalWaitEstimate.Source.MODEL -> L("signal.src.model")
    }

    private fun lookup(key: String): String? { val v = L(key); return if (v == key) null else v }

    fun highway(highway: String): String {
        val normalized = when (val h = highway.lowercase()) {
            "motorway_link", "trunk_link", "primary_link", "secondary_link", "tertiary_link" -> "link"
            "bus_guideway" -> "busway"
            else -> h
        }
        return lookup("highway.$normalized") ?: L("highway.road")
    }

    fun valhallaRoadClass(roadClass: String?): String? = roadClass?.let { lookup("roadClass.$it") ?: it }
    fun valhallaSurface(surface: String?): String? = surface?.let { lookup("vsurface.$it") ?: it }

    fun osmSurface(surface: String?): String? {
        val s = surface?.lowercase()
        if (s.isNullOrEmpty()) return null
        return when (s) {
            "asphalt" -> L("osmSurface.asphalt")
            "concrete", "concrete:plates", "concrete:lanes" -> L("osmSurface.concrete")
            "paved" -> L("osmSurface.paved")
            "paving_stones", "sett", "cobblestone", "unhewn_cobblestone" -> L("osmSurface.cobblestone")
            "compacted", "fine_gravel", "gravel", "pebblestone" -> L("osmSurface.gravel")
            "unpaved", "dirt", "earth", "ground", "mud", "sand", "grass" -> L("osmSurface.dirt")
            else -> s
        }
    }

    fun roadName(road: RoadSegmentInfo): String {
        if (!road.name.isNullOrEmpty()) return road.name!!
        if (!road.ref.isNullOrEmpty()) return road.ref!!
        return highway(road.highway)
    }

    // Weather

    fun weatherCondition(code: Int?): String {
        if (code == null) return L("common.noDataCap")
        return lookup("wmo.$code") ?: L("wmo.other", code)
    }

    private fun temperature(t: Double): String {
        val v = t.roundToInt()
        return if (v > 0) "+$v°" else if (v < 0) "-${abs(v)}°" else "0°"
    }

    fun weatherSummary(s: WeatherSnapshot): String {
        val parts = ArrayList<String>()
        s.temperatureC?.let { if (it.isFinite()) parts.add(temperature(it)) }
        if (s.weatherCode != null) {
            val d = weatherCondition(s.weatherCode)
            parts.add(d.take(1).lowercase(LocalizationManager.language.locale) + d.drop(1))
        }
        s.windSpeedKmh?.let { if (it.isFinite()) parts.add(L("weather.wind", max(0.0, it).roundToInt())) }
        return if (parts.isEmpty()) L("weather.noData") else parts.joinToString(", ")
    }

    fun weatherWarnings(s: WeatherSnapshot): List<String> {
        val w = ArrayList<String>()
        val code = s.weatherCode ?: -1
        val temp = s.temperatureC?.takeIf { it.isFinite() }
        val precipitation = max(s.precipitationMm ?: 0.0, 0.0)
        val snowfall = max(s.snowfallCm ?: 0.0, 0.0)
        val freezing = setOf(56, 57, 66, 67)
        val snow = setOf(71, 73, 75, 77, 85, 86)
        val nearFreezing = temp?.let { it <= 1 } ?: false
        if (code in freezing || (nearFreezing && (precipitation > 0 || snowfall > 0 || code in snow || code == 48))) {
            w.add(L("weather.warn.ice"))
        }
        if (code == 45 || code == 48 || (s.visibilityMeters?.let { it.isFinite() && it < 1000 } ?: false)) w.add(L("weather.warn.fog"))
        if (code in snow || snowfall > 0) w.add(L("weather.warn.snow"))
        if (code == 65 || code == 82 || precipitation >= 4) w.add(L("weather.warn.heavyRain"))
        if (code in 95..99) w.add(L("weather.warn.thunder"))
        s.windGustsKmh?.let { if (it.isFinite() && it >= 50) w.add(L("weather.warn.wind", it.roundToInt())) }
        return w
    }

    /** Timeline texts in the app language (iOS `RouteTimelineText.app`). */
    fun timelineText(): RouteTimelineText = RouteTimelineText(
        engineSource = { if (it == RouteSource.APPLE) L("timeline.source.apple") else L("timeline.source.engine", it.badge) },
        lanesDetail = { total, good -> if (good > 0) L("timeline.lanes.suitable", total, good) else L("timeline.lanes", total) },
        destination = L("weather.destination"),
        speedLimitTitle = { kmh -> kmh?.let { L("timeline.limit", it) } ?: L("timeline.limit.none") },
        speedLimitDetail = { isFirst, length -> if (isFirst) L("timeline.limit.atStart") else L("timeline.limit.for", distance(length)) },
        laneChangeTitle = { from, to -> if (to > from) L("timeline.lanes.widen", to) else L("timeline.lanes.narrow", to) },
        laneChangeDetail = { L("timeline.lanes.was", it) },
        trafficSignal = L("vehicle.trafficLight"),
        cameraLimit = { L("timeline.cameraLimit", it) },
        featureName = { feature(it) },
        incidentName = { incident(it) },
        incidentSource = { L("timeline.yourMarker", RVFormat.clock(it)) },
    )

    // Android-only strings (not in the iOS tables)

    private val fallback: Map<String, Map<AppLanguage, String>> = mapOf(
        "navx.map.cartoOnly" to mapOf(
            AppLanguage.UZ to "OpenFreeMap vektor xaritasi (OpenStreetMap ma’lumotlari) — bepul, kalitsiz. Sun’iy yo‘ldosh xaritasi uchun kalitsiz bepul manba yo‘q. Xarita faqat ko‘rinadigan hudud uchun yuklanadi va qurilmada keshlanadi (100 MB gacha); tarmoq bo‘lmasa, CARTO Dark xaritasi ishlatiladi.",
            AppLanguage.RU to "Векторная карта OpenFreeMap (данные OpenStreetMap) — бесплатно, без ключа. Бесплатного источника спутниковых снимков без ключа нет. Карта загружается только для видимой области и кешируется на устройстве (до 100 МБ); если стиль недоступен, используется карта CARTO Dark.",
            AppLanguage.EN to "OpenFreeMap vector map (OpenStreetMap data): free, no key. There is no free satellite imagery source without a key. The map is loaded only for the visible area and cached on the device (up to 100 MB); if the style cannot be loaded, the CARTO Dark map is used.",
        ),
        "navx.routing.footer" to mapOf(
            AppLanguage.UZ to "«Avto» Valhalla va OSRM’ni bir vaqtda so‘raydi, mos yo‘nalishlarni birlashtiradi (yo‘lning ≥ 85 % umumiy), variantlarni solishtiradi va eng tezini tanlaydi. FOSSGIS ommaviy serverlari bepul va yengil foydalanish uchun: ilova har biriga soniyasiga ko‘pi bilan bitta so‘rov yuboradi. © OpenStreetMap hissadorlari.",
            AppLanguage.RU to "«Авто» запрашивает Valhalla и OSRM одновременно, объединяет совпадающие маршруты (≥ 85 % пути общие), сравнивает варианты и выбирает самый быстрый. Публичные серверы FOSSGIS бесплатны и рассчитаны на лёгкое использование: приложение отправляет каждому не более одного запроса в секунду. © Участники OpenStreetMap.",
            AppLanguage.EN to "“Auto” queries Valhalla and OSRM at the same time, merges matching routes (≥ 85 % of the path in common), compares the options and picks the fastest. The public FOSSGIS servers are free and meant for light use: the app sends each of them at most one request per second. © OpenStreetMap contributors.",
        ),
        "navx.engine.auto" to mapOf(
            AppLanguage.UZ to "Avto: Valhalla + OSRM, solishtirilgan",
            AppLanguage.RU to "Авто: Valhalla + OSRM, со сравнением",
            AppLanguage.EN to "Auto: Valhalla + OSRM, compared",
        ),
        "navx.searchProvider" to mapOf(
            AppLanguage.UZ to "Qidiruv: Photon (komoot), © OpenStreetMap hissadorlari",
            AppLanguage.RU to "Поиск: Photon (komoot), © участники OpenStreetMap",
            AppLanguage.EN to "Search: Photon (komoot), © OpenStreetMap contributors",
        ),
        "navx.wazeMissing" to mapOf(
            AppLanguage.UZ to "Waze yoki brauzer topilmadi",
            AppLanguage.RU to "Не найдено ни Waze, ни браузера",
            AppLanguage.EN to "Neither Waze nor a browser was found",
        ),
    )

    /** Android-only string in the app language. */
    fun x(key: String, vararg args: Any?): String {
        val table = fallback[key] ?: return L(key, *args)
        val text = table[LocalizationManager.language] ?: table[AppLanguage.EN] ?: key
        return if (args.isEmpty()) text else try {
            String.format(LocalizationManager.language.locale, text, *args)
        } catch (_: Exception) { text }
    }

    fun percent(share: Double): Int = (share * 100).roundToInt()

    @Suppress("unused")
    private val localeUS: Locale = Locale.US
}
