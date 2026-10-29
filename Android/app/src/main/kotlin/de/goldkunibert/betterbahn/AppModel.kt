package de.goldkunibert.betterbahn

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import de.goldkunibert.betterbahn.data.ConnectionSearch
import de.goldkunibert.betterbahn.data.Notifier
import de.goldkunibert.betterbahn.data.SavedRefresh
import de.goldkunibert.betterbahn.data.SavedJourney
import de.goldkunibert.betterbahn.data.Store
import de.goldkunibert.betterbahn.kit.BoardEntryDisplay
import de.goldkunibert.betterbahn.kit.JourneyDisplay
import de.goldkunibert.betterbahn.kit.Kit
import de.goldkunibert.betterbahn.kit.Product
import de.goldkunibert.betterbahn.kit.Station
import de.goldkunibert.betterbahn.kit.TrainRun
import de.goldkunibert.betterbahn.ui.connections.ResultsState
import de.goldkunibert.betterbahn.ui.departures.BoardState
import kotlinx.coroutines.launch
import java.util.UUID

/** The app's tabs, as on iOS. */
enum class Tab(val title: String) { Connections("Verbindungen"), Departures("Abfahrten"), Trips("Reisen"), Settings("Mehr") }

/** A screen pushed onto a tab. */
sealed interface Route {
    class Results(search: ConnectionSearch) : Route {
        val state = ResultsState(search)
    }
    class Detail(journey: JourneyDisplay) : Route {
        /** The journey as last loaded, so going back to it keeps the live data. */
        var journey by mutableStateOf(journey)
        var completed = false
    }
    /** A train's run: from a board entry, or a journey's leg. */
    data class TripFromBoard(val entry: BoardEntryDisplay) : Route
    data class TripFromLeg(val journey: JourneyDisplay, val legIndex: Int) : Route
    data object PastTrips : Route
    data object TrainSearch : Route
    /** A train found by its number, already loaded. */
    data class TripLoaded(val run: TrainRun) : Route
}

/** The connection search being filled in, kept while switching tabs. */
data class SearchForm(
    val from: Station? = null,
    val to: Station? = null,
    val via: List<Station> = emptyList(),
    val date: Long? = null,
    val isArrival: Boolean = false,
    val products: Set<Product> = Product.all,
    val maxTransfers: Int? = null,
    val onlyValidTicket: Boolean = false,
) {
    fun search(): ConnectionSearch? {
        val from = from ?: return null
        val to = to ?: return null
        return ConnectionSearch(from, to, via, date, isArrival && via.isEmpty(), products, maxTransfers, onlyValidTicket)
    }
}

/** The single app state (`AppModel` on iOS): storage, saved journeys as shown, navigation per tab. */
class AppModel(application: Application) : AndroidViewModel(application) {
    val store = Store.get(application)

    var tab by mutableStateOf(Tab.Connections)
    var form by mutableStateOf(SearchForm())
    val board = BoardState()
    private val stacks = Tab.entries.associateWith { mutableStateListOf<Route>() }

    fun stack(tab: Tab): List<Route> = stacks.getValue(tab)
    fun push(route: Route) = stacks.getValue(tab).add(route)

    /** False when the tab was already at its start, so the system handles Back. */
    fun pop(): Boolean = stacks.getValue(tab).removeLastOrNull() != null

    fun selectTab(selected: Tab) {
        // Tapping the open tab again goes back to its start, as on iOS.
        if (selected == tab) stacks.getValue(tab).clear()
        tab = selected
    }

    /** Saved journeys as the Kit describes them, by `SavedJourney.id`. */
    val savedDisplays = mutableStateMapOf<String, JourneyDisplay>()
    var refreshingSaved by mutableStateOf(false)
        private set

    init {
        // Describe saved journeys whenever the list changes (saved here, or refreshed in the background).
        viewModelScope.launch {
            store.savedJourneys.collect { saved ->
                val missing = saved.filter { savedDisplays[it.id]?.id != it.journeyId }
                if (missing.isNotEmpty()) {
                    runCatching { Kit.describeJourneys(missing.map { it.journey }) }.onSuccess { displays ->
                        missing.zip(displays).forEach { (entry, display) -> savedDisplays[entry.id] = display }
                    }
                }
                savedDisplays.keys.retainAll(saved.map { it.id }.toSet())
            }
        }
    }

    /** Set once the first journey is saved: time to ask for notifications (the activity asks). */
    var wantsNotificationPermission by mutableStateOf(false)

    fun isSaved(journey: JourneyDisplay) = store.savedEntry(journey.id) != null

    fun toggleSaved(journey: JourneyDisplay) {
        val existing = store.savedEntry(journey.id)
        if (existing != null) {
            store.unsave(existing.id)
            savedDisplays.remove(existing.id)
            return
        }
        val entry = SavedJourney(UUID.randomUUID().toString(), journey.id, System.currentTimeMillis(), journey.raw)
        savedDisplays[entry.id] = journey
        store.save(entry) { savedDisplays[it.id]?.journey?.departure?.planned ?: Long.MAX_VALUE }
        SavedRefresh.schedule(getApplication())
        if (!Notifier.canNotify(getApplication())) wantsNotificationPermission = true
    }

    fun deleteSaved(id: String) {
        store.unsave(id)
        savedDisplays.remove(id)
    }

    /** Fresh live data and notifications for saved journeys departing within 24 hours (`SavedRefresh`). */
    fun refreshSaved() {
        if (refreshingSaved) return
        refreshingSaved = true
        viewModelScope.launch {
            SavedRefresh.run(getApplication()) { id, fresh -> savedDisplays[id] = fresh }
            refreshingSaved = false
        }
    }

    /** Opens a saved journey, from its notification. */
    fun openSaved(id: String) {
        val display = savedDisplays[id] ?: return
        tab = Tab.Trips
        stacks.getValue(Tab.Trips).apply { clear(); add(Route.Detail(display)) }
    }

    /** Updates a saved journey after its detail view loaded fresher data. */
    fun updateSaved(journey: JourneyDisplay, fresh: JourneyDisplay) {
        val entry = store.savedEntry(journey.id) ?: return
        savedDisplays[entry.id] = fresh
        store.update(entry.id, fresh.id, fresh.raw)
    }

    fun rememberStation(station: Station) = store.rememberStation(station)

    /** A shared DB connection being looked up, and what went wrong if it wasn't found. */
    var importing by mutableStateOf(false)
        private set
    var importError by mutableStateOf<String?>(null)

    /** Opens a connection shared from DB Navigator in the connections tab (the share extension on iOS). */
    fun importShared(text: String) {
        importing = true
        importError = null
        viewModelScope.launch {
            runCatching { Kit.importShared(text) }
                .onSuccess { journey ->
                    tab = Tab.Connections
                    push(Route.Detail(journey))
                }
                .onFailure { importError = it.message ?: "Die Verbindung wurde nicht gefunden." }
            importing = false
        }
    }
}
