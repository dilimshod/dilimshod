package uz.roadvis.app.l10n

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.util.Locale

/** The three UI / voice languages of RoadVis. Uzbek (Latin) is the default (port of iOS `AppLanguage`). */
enum class AppLanguage(val raw: String, val displayName: String, val voiceLanguageCode: String, val localeTag: String) {
    UZ("uz", "O‘zbekcha", "uz-UZ", "uz-Latn-UZ"),
    RU("ru", "Русский", "ru-RU", "ru-RU"),
    EN("en", "English", "en-US", "en-US");

    val shortCode: String get() = raw.uppercase()
    val locale: Locale get() = Locale.forLanguageTag(localeTag)

    val strings: Map<String, String>
        get() = when (this) {
            UZ -> UzStrings.table
            RU -> RuStrings.table
            EN -> EnStrings.table
        }

    companion object {
        val DEFAULT = UZ
        const val STORAGE_KEY = "rv.appLanguage"
        fun fromRaw(raw: String?): AppLanguage = entries.firstOrNull { it.raw == raw } ?: DEFAULT
    }
}

/**
 * Holds the current app language. `language` is Compose state, so every composable that calls [L]
 * recomposes when the user picks another language. Persisted in SharedPreferences ("rv.appLanguage").
 */
object LocalizationManager {
    private var prefs: android.content.SharedPreferences? = null
    private val listeners = mutableListOf<(AppLanguage) -> Unit>()

    var language: AppLanguage by mutableStateOf(AppLanguage.DEFAULT)
        private set

    fun init(context: Context) {
        val p = context.getSharedPreferences("roadvis", Context.MODE_PRIVATE)
        prefs = p
        language = AppLanguage.fromRaw(p.getString(AppLanguage.STORAGE_KEY, null))
    }

    fun setLanguage(lang: AppLanguage) {
        if (lang == language) return
        language = lang
        prefs?.edit()?.putString(AppLanguage.STORAGE_KEY, lang.raw)?.apply()
        listeners.toList().forEach { it(lang) }
    }

    fun addListener(l: (AppLanguage) -> Unit) { listeners += l }

    fun string(key: String, lang: AppLanguage = language): String =
        lang.strings[key] ?: AppLanguage.EN.strings[key] ?: key

    fun format(key: String, lang: AppLanguage = language, vararg args: Any?): String =
        try { String.format(lang.locale, string(key, lang), *args) } catch (_: Exception) { string(key, lang) }
}

/** Localized string for a stable key, e.g. `L("about.title")`. */
fun L(key: String): String = LocalizationManager.string(key)

/** Localized format string, e.g. `L("voice.inMeters", 300)`. */
fun L(key: String, vararg args: Any?): String = LocalizationManager.format(key, LocalizationManager.language, *args)

/** Localized string in an explicit language (e.g. for the spoken phrase language). */
fun Lin(key: String, lang: AppLanguage): String = LocalizationManager.string(key, lang)
