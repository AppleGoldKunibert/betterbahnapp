@file:OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)

package de.goldkunibert.betterbahn.ui.connections

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.AssistChip
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import de.goldkunibert.betterbahn.AppModel
import de.goldkunibert.betterbahn.Route
import de.goldkunibert.betterbahn.data.ConnectionSearch
import de.goldkunibert.betterbahn.kit.JourneyDisplay
import de.goldkunibert.betterbahn.kit.Kit
import de.goldkunibert.betterbahn.kit.Product
import de.goldkunibert.betterbahn.ui.JourneyCard
import de.goldkunibert.betterbahn.ui.TimeSelector
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/** What the results screen shows, kept in its route so going back to it doesn't search again. */
class ResultsState(initial: ConnectionSearch) {
    var search by mutableStateOf(initial)
    var journeys by mutableStateOf<List<JourneyDisplay>?>(null)
    var hidden by mutableIntStateOf(0)
    var earlier by mutableStateOf<String?>(null)
    var later by mutableStateOf<String?>(null)
    var error by mutableStateOf<String?>(null)
    var refreshing by mutableStateOf(false)
    var paging by mutableStateOf(false)
    var reload by mutableIntStateOf(0)
    /** The search and reload count the list is for. */
    var loadedFor: Pair<ConnectionSearch, Int>? = null
}

/** The connections found (`JourneyResultsView`): first page, then earlier and later ones; pull to reload. */
@Composable
fun ResultsScreen(model: AppModel, state: ResultsState) {
    var search by state::search
    var journeys by state::journeys
    var earlier by state::earlier
    var later by state::later
    var error by state::error
    var refreshing by state::refreshing
    var paging by state::paging
    var reload by state::reload
    val scope = rememberCoroutineScope()
    val ticket by model.store.ticketType.collectAsState()

    suspend fun page(cursor: String?) = Kit.journeys(
        search.from, search.to, search.date ?: System.currentTimeMillis(), search.isArrival, cursor,
        products = search.products.takeIf { it != Product.all }, maxTransfers = search.maxTransfers, via = search.via,
        ticket = ticket.takeIf { search.onlyValidTicket },
    )

    LaunchedEffect(search, reload) {
        if (state.loadedFor == search to reload) return@LaunchedEffect
        error = null
        try {
            val loaded = page(null)
            journeys = loaded.journeys
            state.hidden = loaded.hiddenCount
            earlier = loaded.earlierCursor
            later = loaded.laterCursor
            state.loadedFor = search to reload
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            error = e.message ?: "Die Suche hat nicht geklappt."
        }
        refreshing = false
    }

    fun loadMore(cursor: String, prepend: Boolean) {
        if (paging) return
        paging = true
        scope.launch {
            runCatching { page(cursor) }.onSuccess { loaded ->
                val current = journeys.orEmpty()
                val ids = current.map { it.id }.toSet()
                val fresh = loaded.journeys.filter { it.id !in ids }
                state.hidden += loaded.hiddenCount
                if (prepend) {
                    journeys = fresh + current
                    earlier = loaded.earlierCursor
                } else {
                    journeys = current + fresh
                    later = loaded.laterCursor
                }
            }
            paging = false
        }
    }

    Column(Modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text("${search.from.shownName} → ${search.to.shownName}", maxLines = 1) },
            navigationIcon = { IconButton(onClick = { model.pop() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Zurück") } },
        )
        if (search.via.isNotEmpty()) {
            Text(
                "über " + search.via.joinToString(", ") { it.shownName },
                Modifier.padding(horizontal = 16.dp),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        FlowRow(Modifier.padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            TimeSelector(search.date, onChange = { search = search.copy(date = it); journeys = null })
            search.maxTransfers?.let {
                AssistChip(onClick = {}, label = { Text(if (it == 0) "Direkt" else "≤ $it Umstieg${if (it == 1) "" else "e"}") })
            }
            if (search.products != Product.all) AssistChip(onClick = {}, label = { Text("Verkehrsmittel gefiltert") })
            if (search.isArrival) AssistChip(onClick = {}, label = { Text("Ankunft") })
            if (search.onlyValidTicket) AssistChip(onClick = {}, label = { Text(ticket.filterTitle) })
        }
        PullToRefreshBox(
            isRefreshing = refreshing,
            onRefresh = { refreshing = true; reload++ },
            modifier = Modifier.fillMaxSize(),
        ) {
            val list = journeys
            when {
                error != null && list == null -> Message(error!!, "Erneut versuchen") { reload++ }
                list == null -> Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                    CircularProgressIndicator()
                    Text("Suche Verbindungen …", Modifier.padding(top = 12.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                list.isEmpty() -> Message("Keine Verbindungen\nVersuch eine andere Uhrzeit oder weniger Filter.")
                else -> LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    // With the ticket filter: the ones the ticket covers; the border crossers only when nothing else fits.
                    val covered = list.filter { it.validWithTicket != false }
                    val shown = if (search.onlyValidTicket && covered.isNotEmpty()) covered else list
                    val notUsable = state.hidden + list.size - shown.size
                    if (search.onlyValidTicket && notUsable > 0) {
                        item {
                            Text("$notUsable nicht mit ${ticket.shortName} nutzbar", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                    earlier?.let { cursor ->
                        item { PageButton("Frühere Verbindungen", paging) { loadMore(cursor, prepend = true) } }
                    }
                    items(shown, key = { it.id }) { journey ->
                        JourneyCard(journey) { model.push(Route.Detail(journey)) }
                    }
                    later?.let { cursor ->
                        item { PageButton("Spätere Verbindungen", paging) { loadMore(cursor, prepend = false) } }
                    }
                }
            }
        }
    }
}

@Composable
private fun PageButton(title: String, loading: Boolean, onClick: () -> Unit) {
    OutlinedButton(onClick = onClick, enabled = !loading, modifier = Modifier.fillMaxWidth()) {
        if (loading) CircularProgressIndicator(Modifier.padding(end = 8.dp).size(16.dp), strokeWidth = 2.dp)
        Text(title)
    }
}

/** A centred note, optionally with a button. */
@Composable
fun Message(text: String, action: String? = null, onAction: () -> Unit = {}) {
    Box(Modifier.fillMaxSize().padding(32.dp), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(text, textAlign = TextAlign.Center, color = MaterialTheme.colorScheme.onSurfaceVariant)
            action?.let { TextButton(onClick = onAction) { Text(it) } }
        }
    }
}
