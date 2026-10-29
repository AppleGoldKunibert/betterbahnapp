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
    val date: Long? = null,
    val isArrival: Boolean = false,
    val products: Set<Product> = Product.all,
    val maxTransfers: Int? = null,
) {
    fun search(): ConnectionSearch? {
        val from = from ?: return null
        val to = to ?: return null
        return ConnectionSearch(from, to, date, isArrival, products, maxTransfers)
    }
}

/** The single app state (`AppModel` on iOS): storage, saved journeys as shown, navigation per tab. */
class AppModel(application: Application) : AndroidViewModel(application) {
    val store = Store(application)

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
        viewModelScope.launch { describeSaved() }
    }

    private suspend fun describeSaved() {
        val saved = store.savedJourneys.value
        runCatching { Kit.describeJourneys(saved.map { it.journey }) }.onSuccess { displays ->
            saved.zip(displays).forEach { (entry, display) -> savedDisplays[entry.id] = display }
        }
    }

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
    }

    fun deleteSaved(id: String) {
        store.unsave(id)
        savedDisplays.remove(id)
    }

    /** Fresh live data for saved journeys departing within 24 hours and not over yet (`refreshSavedJourneys`). */
    fun refreshSaved() {
        if (refreshingSaved) return
        refreshingSaved = true
        viewModelScope.launch {
            val now = System.currentTimeMillis()
            for (entry in store.savedJourneys.value) {
                val display = savedDisplays[entry.id] ?: continue
                val departure = display.journey.departure?.planned ?: continue
                if (display.isOver || departure - now > 24 * 3600_000L) continue
                runCatching { Kit.refreshJourney(entry.journey) }.onSuccess { fresh ->
                    savedDisplays[entry.id] = fresh
                    store.update(entry.id, fresh.id, fresh.raw)
                }
            }
            refreshingSaved = false
        }
    }

    /** Updates a saved journey after its detail view loaded fresher data. */
    fun updateSaved(journey: JourneyDisplay, fresh: JourneyDisplay) {
        val entry = store.savedEntry(journey.id) ?: return
        savedDisplays[entry.id] = fresh
        store.update(entry.id, fresh.id, fresh.raw)
    }

    fun rememberStation(station: Station) = store.rememberStation(station)
}
