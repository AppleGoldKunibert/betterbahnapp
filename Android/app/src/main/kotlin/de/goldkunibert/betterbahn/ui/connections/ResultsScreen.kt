@file:OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)

package de.goldkunibert.betterbahn.ui.connections

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Tag
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AssistChip
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import de.goldkunibert.betterbahn.AppModel
import de.goldkunibert.betterbahn.Route
import de.goldkunibert.betterbahn.data.ConnectionSearch
import de.goldkunibert.betterbahn.kit.JourneyDisplay
import de.goldkunibert.betterbahn.kit.Kit
import de.goldkunibert.betterbahn.kit.Product
import de.goldkunibert.betterbahn.kit.TicketType
import de.goldkunibert.betterbahn.kit.TrainCandidate
import de.goldkunibert.betterbahn.kit.TrainRoutePlan
import de.goldkunibert.betterbahn.ui.Brand
import de.goldkunibert.betterbahn.ui.DesignCard
import de.goldkunibert.betterbahn.ui.JourneyCard
import de.goldkunibert.betterbahn.ui.SlightDelay
import de.goldkunibert.betterbahn.ui.Ticket
import de.goldkunibert.betterbahn.ui.TicketValueField
import de.goldkunibert.betterbahn.ui.TimeSelector
import de.goldkunibert.betterbahn.ui.compactDuration
import de.goldkunibert.betterbahn.ui.isFahrkarte
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import kotlinx.serialization.json.jsonPrimitive

/** How far around the search time the trains calling at both ends are looked up, as on iOS (3 hours). */
private const val LOOKUP_WINDOW = 180 * 60_000L

/** A route counts as noticeably slower than the free choice from an hour of extra travel time. */
private const val SLOW_ROUTE_SECONDS = 60 * 60.0

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
    /** Each result's live times once it showed (`liveResults`). */
    val live = mutableStateMapOf<String, JourneyDisplay>()

    /** "Zug vorgeben": the trains the route must ride, and the routes found with them. */
    val requirements = mutableStateListOf<TrainCandidate>()
    var plan by mutableStateOf<TrainRoutePlan?>(null)
    var planError by mutableStateOf<String?>(null)
    var planning by mutableStateOf(false)
}

/**
 * The connections found (`JourneyResultsView`): first page, then earlier and later ones; pull to reload. Once a
 * page shows it is checked once more (detours, platforms, train names), and each card loads its live times.
 */
@Composable
fun ResultsScreen(model: AppModel, state: ResultsState) {
    var search by state::search
    var journeys by state::journeys
    var error by state::error
    val scope = rememberCoroutineScope()
    val ticket by model.store.ticketType.collectAsState()
    val expert by model.store.settings.expertMode.state.collectAsState()
    val trainChoiceSetting by model.store.settings.expertTrainChoice.state.collectAsState()
    val trainChoice = expert && trainChoiceSetting
    var pickingTrain by remember { mutableStateOf(false) }
    val filterTicket = ticket.takeIf { search.onlyValidTicket }
    val date = search.date ?: System.currentTimeMillis()

    suspend fun page(cursor: String?) = Kit.journeys(
        search.from, search.to, date, search.isArrival, cursor,
        products = search.products.takeIf { it != Product.all }, maxTransfers = search.maxTransfers, via = search.via,
        ticket = filterTicket, viaOptions = search.viaOptions,
    )

    /** Replaces the loaded ones of [loaded] with the checked versions, keeping the list's order. */
    suspend fun refine(loaded: List<JourneyDisplay>, start: Long, end: Long) {
        if (loaded.isEmpty()) return
        val refined = runCatching {
            Kit.refineJourneys(loaded.map { it.raw }, search.from, search.to, start, end, search.via.isNotEmpty(), filterTicket)
        }.getOrNull() ?: return
        val byId = refined.associateBy { it.id }
        val checked = loaded.map { it.id }.toSet()
        journeys = journeys?.mapNotNull { if (it.id in checked) byId[it.id] else it }
    }

    suspend fun replan() {
        if (state.requirements.isEmpty()) return
        state.planning = true
        try {
            state.plan = Kit.planTrainRoute(state.requirements.mapNotNull { it.requirement }, search.from, search.to, date, filterTicket)
            state.planError = null
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            state.plan = null
            state.planError = e.message ?: "Mit diesen Zügen haben wir keine Verbindung gefunden."
        }
        state.planning = false
    }

    LaunchedEffect(search, state.reload) {
        if (state.loadedFor == search to state.reload) return@LaunchedEffect
        error = null
        try {
            val loaded = page(null)
            journeys = loaded.journeys
            state.hidden = loaded.hiddenCount
            state.earlier = loaded.earlierCursor
            state.later = loaded.laterCursor
            state.live.clear()
            state.loadedFor = search to state.reload
            state.refreshing = false
            val start = if (search.isArrival) date - LOOKUP_WINDOW else date
            refine(loaded.journeys, start, start + 2 * LOOKUP_WINDOW)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            error = e.message ?: "Die Suche hat nicht geklappt."
        }
        state.refreshing = false
        replan()
    }

    fun loadMore(cursor: String, prepend: Boolean) {
        if (state.paging) return
        state.paging = true
        scope.launch {
            runCatching { page(cursor) }.onSuccess { loaded ->
                val current = journeys.orEmpty()
                val ids = current.map { it.id }.toSet()
                val fresh = loaded.journeys.filter { it.id !in ids }
                state.hidden += loaded.hiddenCount
                if (prepend) {
                    journeys = fresh + current
                    state.earlier = loaded.earlierCursor
                } else {
                    journeys = current + fresh
                    state.later = loaded.laterCursor
                }
                state.paging = false
                // A further page: its own window.
                val start = fresh.mapNotNull { it.journey.departure?.planned }.minOrNull()
                val end = fresh.mapNotNull { it.journey.arrival?.planned }.maxOrNull()
                if (start != null && end != null) refine(fresh, start, maxOf(start, end))
            }.onFailure { state.paging = false }
        }
    }

    Column(Modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text(if (isFahrkarte) "" else "Verbindungen") },
            navigationIcon = { IconButton(onClick = { model.pop() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Zurück") } },
            colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent),
        )
        PullToRefreshBox(
            isRefreshing = state.refreshing,
            onRefresh = { state.refreshing = true; state.reload++ },
            modifier = Modifier.fillMaxSize(),
        ) {
            val list = journeys
            val requirements = state.requirements
            // With the ticket filter: the ones the ticket covers; the border crossers only when nothing else fits.
            val covered = list.orEmpty().filter { it.validWithTicket != false }
            val results = if (search.onlyValidTicket && covered.isNotEmpty()) covered else list.orEmpty()
            val shown = if (requirements.isNotEmpty()) state.plan?.journeys.orEmpty() else results
            val showsBorderFallback = requirements.isEmpty() && search.onlyValidTicket && covered.isEmpty() && list.orEmpty().isNotEmpty()
            val notUsable = state.hidden + list.orEmpty().size - results.size

            LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                item { Header(search, ticket, onTime = { search = search.copy(date = it); journeys = null }) }
                error?.let { message ->
                    if (list == null) item { Message(message, "Erneut versuchen") { state.reload++ } }
                }
                if (trainChoice) {
                    item {
                        TrainBar(requirements.isEmpty(), onPick = { pickingTrain = true }, onReset = {
                            requirements.clear()
                            state.plan = null
                            state.planError = null
                        })
                    }
                }
                if (requirements.isNotEmpty()) {
                    item { RequirementList(state, onRemove = { candidate ->
                        requirements.remove(candidate)
                        if (requirements.isEmpty()) { state.plan = null; state.planError = null } else scope.launch { replan() }
                    }) }
                    if (state.planning) item { Progress("Suche Verbindungen mit deinen Zügen …") }
                    state.planError?.let { item { Banner(it) } }
                    val baseline = list.orEmpty().filter { !it.isCancelled }.mapNotNull { it.durationSeconds }.minOrNull()
                    val forced = state.plan?.journeys?.firstOrNull()?.durationSeconds
                    if (baseline != null && forced != null && forced - baseline >= SLOW_ROUTE_SECONDS) {
                        item { Banner("Mit diesem Zug bist du ${compactDuration(forced - baseline)} länger unterwegs.") }
                    }
                    if (state.plan?.breaksBoardingRules == true) {
                        item { Banner("An einem gewählten Halt ist Ein- oder Aussteigen laut Fahrplan nicht erlaubt.") }
                    }
                    if (shown.isNotEmpty()) item { SectionTitle(if (requirements.size == 1) "Routen mit diesem Zug" else "Routen mit diesen Zügen") }
                }
                if (showsBorderFallback) item { Banner(borderFallbackText(ticket, list.orEmpty())) }
                if (list == null && error == null) item { Progress("Suche Verbindungen …") }
                if (requirements.isEmpty()) {
                    state.earlier?.let { cursor -> item { PageButton("Frühere Verbindungen", state.paging) { loadMore(cursor, prepend = true) } } }
                }
                itemsIndexed(shown, key = { _, it -> it.id }) { index, result ->
                    val journey = state.live[result.id] ?: result
                    LaunchedEffect(result.id) {
                        if (state.live[result.id] == null) runCatching { Kit.checkLive(result.raw) }.getOrNull()?.let { state.live[result.id] = it }
                    }
                    JourneyCard(journey, highlight = if (requirements.isNotEmpty() && index == 0) Brand else null) {
                        model.push(Route.Detail(journey))
                    }
                }
                if (requirements.isEmpty()) {
                    state.later?.let { cursor -> item { PageButton("Spätere Verbindungen", state.paging) { loadMore(cursor, prepend = false) } } }
                }
                if (list != null && !state.planning && shown.isEmpty() && state.planError == null) {
                    item {
                        Message(
                            "Keine Verbindungen\n" + if (requirements.isEmpty()) "Versuch eine andere Uhrzeit oder weniger Filter."
                            else "Mit diesen Zügen haben wir keine Verbindung gefunden.",
                        )
                    }
                }
                if (list != null) {
                    item {
                        Column(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            if (search.onlyValidTicket && notUsable > 0 && requirements.isEmpty()) {
                                AssistChip(onClick = {}, label = { Text("$notUsable nicht mit ${ticket.shortName} nutzbar") })
                            }
                            if (list.firstOrNull()?.journey?.source == "transitous") {
                                AssistChip(onClick = {}, label = { Text("Fahrplandaten: Transitous") })
                            }
                        }
                    }
                }
            }
        }
    }

    if (pickingTrain) {
        val base = state.plan?.journeys?.take(2).orEmpty() + journeys.orEmpty().take(4)
        val stations = (listOf(search.from) + base.flatMap { it.journey.transitLegs.map { leg -> leg.origin } }).distinctBy { it.id }
        TrainChoiceSheet(
            stations = stations,
            target = search.to,
            date = date,
            onPick = { candidate ->
                pickingTrain = false
                state.requirements.add(candidate)
                scope.launch { replan() }
            },
            onDismiss = { pickingTrain = false },
        )
    }
}

/**
 * The search on top: Minimal "From ↳ To" and the vias, Fahrkarte a "Von"/"Nach" ticket; then chips for the time
 * (tap to change) and the filters.
 */
@Composable
private fun Header(search: ConnectionSearch, ticket: TicketType, onTime: (Long?) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        val via = search.via.mapIndexed { index, station ->
            val stay = search.viaOptions.getOrNull(index)?.minStayMinutes ?: 0
            if (stay > 0) "${station.shownName} (≥ $stay Min.)" else station.shownName
        }
        if (isFahrkarte) {
            Ticket(sections = listOf(
                {
                    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        TicketValueField("Von", search.from.shownName)
                        TicketValueField("Nach", search.to.shownName)
                    }
                },
                { Box(Modifier.padding(horizontal = 16.dp, vertical = 10.dp)) { Chips(search, ticket, via, onTime) } },
            ))
        } else {
            Column {
                Text(search.from.shownName, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, maxLines = 2, overflow = TextOverflow.Ellipsis)
                Text("↳ ${search.to.shownName}", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
            Chips(search, ticket, via, onTime)
        }
    }
}

@Composable
private fun Chips(search: ConnectionSearch, ticket: TicketType, via: List<String>, onTime: (Long?) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        if (via.isNotEmpty()) {
            Text("über " + via.joinToString(", "), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            TimeSelector(search.date, onChange = onTime)
            if (search.isArrival) AssistChip(onClick = {}, label = { Text("Ankunft") })
            if (search.onlyValidTicket) AssistChip(onClick = {}, label = { Text(ticket.shortName) })
            search.maxTransfers?.let {
                AssistChip(onClick = {}, label = { Text(if (it == 0) "Direkt" else if (it == 1) "≤ 1 Umstieg" else "≤ $it Umstiege") })
            }
            if (search.products != Product.all || search.viaOptions.any { it.products != null }) {
                AssistChip(onClick = {}, label = { Text("Verkehrsmittel gefiltert") })
            }
        }
    }
}

/** The warning when the ticket covers none of the connections: they are abroad entirely, or only reach the border. */
private fun borderFallbackText(ticket: TicketType, results: List<JourneyDisplay>): String =
    if (results.all { it.entirelyAbroad == true }) {
        when (ticket) {
            TicketType.BahnCard100 -> "Auf der kompletten Strecke gilt deine BahnCard 100 nicht!"
            TicketType.Deutschlandticket -> "Auf der kompletten Strecke gilt dein Deutschlandticket nicht!"
        }
    } else {
        when (ticket) {
            TicketType.BahnCard100 -> "Diese Verbindungen führen ins Ausland. Mit der BC100 kommst du nur bis zur Grenze."
            TicketType.Deutschlandticket -> "Diese Verbindungen führen ins Ausland. Mit dem D-Ticket kommst du nur bis zur Grenze."
        }
    }

/** "Bestimmten Zug wählen" / "Weiteren Zug vorgeben", and resetting them (`trainBar`). */
@Composable
private fun TrainBar(isEmpty: Boolean, onPick: () -> Unit, onReset: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedButton(onClick = onPick, modifier = Modifier.weight(1f)) {
            Icon(Icons.Filled.Tag, null, Modifier.padding(end = 6.dp).size(18.dp))
            Text(if (isEmpty) "Bestimmten Zug wählen" else "Weiteren Zug vorgeben")
        }
        if (!isEmpty) FilledTonalIconButton(onClick = onReset) { Icon(Icons.Filled.Refresh, "Alle Züge entfernen") }
    }
}

/** The trains the route must ride, each removable (`requirementList`). */
@Composable
private fun RequirementList(state: ResultsState, onRemove: (TrainCandidate) -> Unit) {
    DesignCard {
        state.requirements.forEachIndexed { index, candidate ->
            if (index > 0) HorizontalDivider(Modifier.padding(start = 16.dp))
            Row(Modifier.padding(start = 16.dp, top = 10.dp, bottom = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    val id = candidate.requirement?.get("id")?.jsonPrimitive?.content
                    Text(state.plan?.resolvedNames?.get(id) ?: candidate.name, fontWeight = FontWeight.SemiBold)
                    Text(requirementSubtitle(candidate), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
                }
                IconButton(onClick = { onRemove(candidate) }) { Icon(Icons.Filled.Close, "Zug entfernen") }
            }
        }
    }
}

private fun requirementSubtitle(candidate: TrainCandidate): String {
    val boarding = candidate.boarding?.station?.shownName ?: return ""
    val exit = candidate.exit?.station?.shownName
    return if (exit != null) "ab $boarding → $exit" else "ab $boarding → schnellster Weg"
}

@Composable
private fun Banner(text: String) {
    DesignCard {
        Row(Modifier.padding(14.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Icon(Icons.Filled.Warning, null, tint = SlightDelay)
            Text(text, style = MaterialTheme.typography.bodyMedium)
        }
    }
}

@Composable
private fun Progress(text: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = 12.dp), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
        CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
        Text(text, Modifier.padding(start = 10.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
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
