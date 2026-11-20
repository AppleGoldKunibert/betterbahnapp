package de.goldkunibert.betterbahn.data

import android.content.SharedPreferences
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** The look of the app (`AppDesign`, Settings › Design): quiet cards, or the search as a ticket. */
enum class AppDesign(val id: String, val displayName: String) {
    Minimal("minimal", "Minimal"),
    Fahrkarte("fahrkarte", "Fahrkarte");

    companion object {
        fun of(id: String?): AppDesign = entries.firstOrNull { it.id == id } ?: Minimal
    }
}

/** What comes along (`BikeOption`): nothing to show, a folding bike or a bike. */
enum class BikeOption(val id: String, val displayName: String, val searchTitle: String?, val searchSubtitle: String?) {
    Hidden("hidden", "Ausblenden", null, null),
    FoldingBike("foldingBike", "Klapprad", "Mit Klapprad", "Zeigt, wo dein Klapprad mitkommt"),
    Bike("bike", "Fahrrad", "Mit Fahrrad", "Zeigt, ob dein Fahrrad mitkommt");

    companion object {
        fun of(id: String?): BikeOption = entries.firstOrNull { it.id == id } ?: Hidden
    }
}

/**
 * The settings the search needs (`AppSettings` on iOS), in the store's SharedPreferences, so Auto Backup takes them
 * along. Each one is a [StateFlow] for Compose.
 */
class Settings(private val prefs: SharedPreferences) {
    private fun bool(key: String, default: Boolean) = Setting(prefs.getBoolean(key, default)) {
        prefs.edit().putBoolean(key, it).apply()
    }

    private fun <T> choice(key: String, read: (String?) -> T, id: (T) -> String) = Setting(read(prefs.getString(key, null))) {
        prefs.edit().putString(key, id(it)).apply()
    }

    val design = choice("appDesign", AppDesign::of) { it.id }
    val bikeOption = choice("bikeOption", BikeOption::of) { it.id }
    /** The search's "Mit Fahrrad": the bike comes along this time. */
    val searchWithBike = bool("searchWithBike", false)
    /** "Nur passende Züge zeigen": the search's ticket filter starts switched on. */
    val ticketFilterByDefault = bool("onlyBC100ByDefault", false)
    val expertMode = bool("expertMode", false)
    val expertTrainChoice = bool("expertTrainChoice", false)
    /** "Zuletzt gesucht" unfolded. */
    val recentSearchesExpanded = bool("recentSearchesExpanded", true)

    /** "Bestimmten Zug wählen" on the results page (`AppSettings.trainChoiceEnabled`). */
    val trainChoiceEnabled: Boolean get() = expertMode.value && expertTrainChoice.value
}

/** One setting: its value as state, written through on every change. */
class Setting<T>(initial: T, private val write: (T) -> Unit) {
    private val flow = MutableStateFlow(initial)
    val state: StateFlow<T> = flow
    val value: T get() = flow.value

    fun set(value: T) {
        flow.value = value
        write(value)
    }
}
