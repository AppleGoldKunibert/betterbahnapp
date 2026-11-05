package de.goldkunibert.betterbahn.data

import android.content.Context
import de.goldkunibert.betterbahn.kit.KitJson
import de.goldkunibert.betterbahn.kit.Product
import de.goldkunibert.betterbahn.kit.Station
import de.goldkunibert.betterbahn.kit.TicketType
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.JsonObject

/** A connection search (`ConnectionSearch` on iOS, without tickets and bikes so far). */
@Serializable
data class ConnectionSearch(
    val from: Station,
    val to: Station,
    /** Stations to pass through, in order; the search then always goes from the chosen time. */
    val via: List<Station> = emptyList(),
    /** Null: now. */
    val date: Long? = null,
    val isArrival: Boolean = false,
    val products: Set<Product> = Product.all,
    val maxTransfers: Int? = null,
    /** Only connections the ticket from the settings covers. */
    val onlyValidTicket: Boolean = false,
)

@Serializable
data class RecentSearch(val from: Station, val to: Station)

/** A saved journey ("Reisen"), the journey as the Kit's JSON, and what the user was already notified about. */
@Serializable
data class SavedJourney(
    val id: String,
    val journeyId: String,
    val savedAt: Long,
    val journey: JsonObject,
    val notified: List<String> = emptyList(),
)

/**
 * What the app keeps on the device: favourite and recent stations, recent searches, saved journeys. JSON in
 * SharedPreferences, like the iOS app's JSON files (without iCloud).
 */
class Store private constructor(context: Context) {
    companion object {
        @Volatile private var shared: Store? = null

        /** One store per process, so the app and the background refresh see the same data. */
        fun get(context: Context): Store =
            shared ?: synchronized(this) { shared ?: Store(context.applicationContext).also { shared = it } }
    }

    private val prefs = context.getSharedPreferences("betterbahn", Context.MODE_PRIVATE)

    private val _favorites = MutableStateFlow(load("favorites", Station.serializer()))
    val favorites: StateFlow<List<Station>> = _favorites

    private val _recentStations = MutableStateFlow(load("recentStations", Station.serializer()))
    val recentStations: StateFlow<List<Station>> = _recentStations

    private val _recentSearches = MutableStateFlow(load("recentSearches", RecentSearch.serializer()))
    val recentSearches: StateFlow<List<RecentSearch>> = _recentSearches

    private val _ticketType = MutableStateFlow(TicketType.of(prefs.getString("ticketType", null)))
    /** The ticket for "Nur Deutschlandticket" & Co. (Einstellungen). */
    val ticketType: StateFlow<TicketType> = _ticketType

    fun setTicketType(type: TicketType) {
        _ticketType.value = type
        prefs.edit().putString("ticketType", type.id).apply()
    }

    private val _savedJourneys = MutableStateFlow(load("savedJourneys", SavedJourney.serializer()))
    val savedJourneys: StateFlow<List<SavedJourney>> = _savedJourneys

    fun isFavorite(station: Station) = _favorites.value.any { it.isSamePlace(station) }

    @Synchronized
    fun toggleFavorite(station: Station) {
        val current = _favorites.value
        val updated = if (isFavorite(station)) current.filterNot { it.isSamePlace(station) } else current + station
        set("favorites", Station.serializer(), _favorites, updated)
    }

    /** Moves a picked station to the front of the recent ones (at most 10, `rememberStation`). */
    @Synchronized
    fun rememberStation(station: Station) {
        val updated = (listOf(station) + _recentStations.value.filterNot { it.isSamePlace(station) }).take(10)
        set("recentStations", Station.serializer(), _recentStations, updated)
    }

    /** At most 8, newest first (`remember(from:to:)`). */
    @Synchronized
    fun rememberSearch(from: Station, to: Station) {
        val search = RecentSearch(from, to)
        val updated = (listOf(search) + _recentSearches.value.filterNot {
            it.from.isSamePlace(from) && it.to.isSamePlace(to)
        }).take(8)
        set("recentSearches", RecentSearch.serializer(), _recentSearches, updated)
    }

    @Synchronized
    fun removeSearch(search: RecentSearch) =
        set("recentSearches", RecentSearch.serializer(), _recentSearches, _recentSearches.value - search)

    @Synchronized
    fun clearHistory() {
        set("recentSearches", RecentSearch.serializer(), _recentSearches, emptyList())
        set("recentStations", Station.serializer(), _recentStations, emptyList())
    }

    fun savedEntry(journeyId: String): SavedJourney? = _savedJourneys.value.firstOrNull { it.journeyId == journeyId }

    /** Saves a journey, the list sorted by departure. */
    @Synchronized
    fun save(entry: SavedJourney, departure: (SavedJourney) -> Long) {
        val updated = (_savedJourneys.value.filterNot { it.journeyId == entry.journeyId } + entry).sortedBy(departure)
        set("savedJourneys", SavedJourney.serializer(), _savedJourneys, updated)
    }

    @Synchronized
    fun unsave(id: String) =
        set("savedJourneys", SavedJourney.serializer(), _savedJourneys, _savedJourneys.value.filterNot { it.id == id })

    /** Fresh data for a saved journey, keeping its place in the list. */
    @Synchronized
    fun update(id: String, journeyId: String, journey: JsonObject, notified: List<String>? = null) {
        val updated = _savedJourneys.value.map {
            if (it.id == id) it.copy(journeyId = journeyId, journey = journey, notified = notified ?: it.notified) else it
        }
        set("savedJourneys", SavedJourney.serializer(), _savedJourneys, updated)
    }

    private fun <T> load(key: String, serializer: KSerializer<T>): List<T> =
        prefs.getString(key, null)?.let {
            runCatching { KitJson.json.decodeFromString(ListSerializer(serializer), it) }.getOrNull()
        } ?: emptyList()

    private fun <T> set(key: String, serializer: KSerializer<T>, flow: MutableStateFlow<List<T>>, value: List<T>) {
        flow.value = value
        prefs.edit().putString(key, KitJson.json.encodeToString(ListSerializer(serializer), value)).apply()
    }
}
