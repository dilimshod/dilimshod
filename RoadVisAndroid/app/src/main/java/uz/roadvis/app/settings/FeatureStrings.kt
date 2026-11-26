package uz.roadvis.app.settings

import uz.roadvis.app.l10n.AppLanguage
import uz.roadvis.app.l10n.L
import uz.roadvis.app.l10n.LocalizationManager

/**
 * Strings of the trips / settings / about features that the generated tables (ported 1:1 from iOS) do not have, plus
 * Android wording for a few table entries that describe iOS-only behaviour (iPhone settings, Mac scripts).
 * Looked up first; everything else goes to [L].
 */
private val featureStrings: Map<AppLanguage, Map<String, String>> = mapOf(
    AppLanguage.UZ to mapOf(
        "android.tripNotif.channel" to "Safar yozuvi",
        "android.tripNotif.text" to "Safar fonda yozilmoqda",
        "android.mapStyle.osmStandard" to "OpenStreetMap (standart)",
        "android.common.share" to "Ulashish",
        "android.common.back" to "Orqaga",
        "android.history.delete" to "O‘chirish",
        "android.report.notFound" to "Safar topilmadi.",
        "language.voice.systemDefault" to "Bu til uchun ovoz o‘rnatilmagan. Android standart ovozdan foydalanadi, talaffuz noto‘g‘ri bo‘lishi mumkin.",
        "language.voice.uzNote" to "Android’da o‘zbek ovozi bo‘lmasa, RoadVis o‘zbekcha ko‘rsatmalarni turkcha (yoki ruscha) ovoz bilan o‘qiydi. Tabiiy ovoz kliplari o‘rnatilgan iboralar uchun ishlatiladi.",
        "language.natural.missing" to "Kliplar o‘rnatilmagan: ilova assets/voice papkasidagi kliplar bilan qayta yig‘ilishi kerak.",
    ),
    AppLanguage.RU to mapOf(
        "android.tripNotif.channel" to "Запись поездки",
        "android.tripNotif.text" to "Поездка записывается в фоне",
        "android.mapStyle.osmStandard" to "OpenStreetMap (стандарт)",
        "android.common.share" to "Поделиться",
        "android.common.back" to "Назад",
        "android.history.delete" to "Удалить",
        "android.report.notFound" to "Поездка не найдена.",
        "language.voice.systemDefault" to "Голос для этого языка не установлен. Android использует голос по умолчанию, произношение может быть неверным.",
        "language.voice.uzNote" to "Если на Android нет узбекского голоса, RoadVis читает узбекские подсказки турецким (или русским) голосом. Для фраз с установленными клипами звучит естественный голос.",
        "language.natural.missing" to "Клипы не установлены: приложение нужно собрать с клипами в assets/voice.",
    ),
    AppLanguage.EN to mapOf(
        "android.tripNotif.channel" to "Trip recording",
        "android.tripNotif.text" to "Recording the trip in the background",
        "android.mapStyle.osmStandard" to "OpenStreetMap (standard)",
        "android.common.share" to "Share",
        "android.common.back" to "Back",
        "android.history.delete" to "Delete",
        "android.report.notFound" to "Trip not found.",
        "language.voice.systemDefault" to "No voice for this language is installed. Android uses its default voice, so pronunciation may be wrong.",
        "language.voice.uzNote" to "When Android has no Uzbek voice, RoadVis reads Uzbek prompts with a Turkish (or Russian) voice. Phrases with installed clips use the natural voice.",
        "language.natural.missing" to "Clips are not installed: the app has to be built with the clips in assets/voice.",
    ),
)

/** Localized string of these features: own fallback table first, then the shared tables. */
fun TL(key: String): String = featureStrings[LocalizationManager.language]?.get(key) ?: L(key)

fun TL(key: String, vararg args: Any?): String {
    val own = featureStrings[LocalizationManager.language]?.get(key) ?: return L(key, *args)
    return try { String.format(LocalizationManager.language.locale, own, *args) } catch (_: Exception) { own }
}
