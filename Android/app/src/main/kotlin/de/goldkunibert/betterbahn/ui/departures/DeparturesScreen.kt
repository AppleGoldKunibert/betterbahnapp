@file:OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)

package de.goldkunibert.betterbahn.ui.departures

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.FilterList
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.StarBorder
import androidx.compose.material.icons.filled.Train
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.SuggestionChip
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import de.goldkunibert.betterbahn.AppModel
import de.goldkunibert.betterbahn.Route
import de.goldkunibert.betterbahn.kit.BoardEntryDisplay
import de.goldkunibert.betterbahn.kit.Kit
import de.goldkunibert.betterbahn.kit.Product
import de.goldkunibert.betterbahn.kit.Station
import de.goldkunibert.betterbahn.ui.LineBadge
import de.goldkunibert.betterbahn.ui.PlatformBadge
import de.goldkunibert.betterbahn.ui.ProductFilterSheet
import de.goldkunibert.betterbahn.ui.StationPicker
import de.goldkunibert.betterbahn.ui.Tag
import de.goldkunibert.betterbahn.ui.TimeSelector
import de.goldkunibert.betterbahn.ui.TimeStack
import de.goldkunibert.betterbahn.ui.connections.Message
import de.goldkunibert.betterbahn.ui.productSummary
import de.goldkunibert.betterbahn.ui.timeString
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private val Gold = Color(0xFFF2B705)

/** The board's choices and entries, kept in the app model while a train is open or another tab shown. */
class BoardState {
    var station by mutableStateOf<Station?>(null)
    var departures by mutableStateOf(true)
    var time by mutableStateOf<Long?>(null)
    var products by mutableStateOf(Product.all)
    var onlyValidTicket by mutableStateOf(false)
    var entries by mutableStateOf<List<BoardEntryDisplay>?>(null)
    var error by mutableStateOf<String?>(null)
    var loadedAt by mutableLongStateOf(0L)
}

/** Minutes per page of the board, as on iOS. */
private const val WINDOW = 90

/**
 * The departure and arrival board (`StationBoardView`): station, departures or arrivals, time, product filter;
 * earlier and later pages; reloads every minute. Favourites when no station is chosen.
 */
@Composable
fun DeparturesScreen(model: AppModel) {
    val board = model.board
    var picking by remember { mutableStateOf(false) }
    var filtering by remember { mutableStateOf(false) }
    var departures by board::departures
    var time by board::time
    var products by board::products
    var onlyValidTicket by board::onlyValidTicket
    val ticket by model.store.ticketType.collectAsState()
    var entries by board::entries
    var error by board::error
    var loadedAt by board::loadedAt
    var refreshing by remember { mutableStateOf(false) }
    var paging by remember { mutableStateOf(false) }
    var reload by remember { mutableIntStateOf(0) }
    val station = board.station
    val favorites by model.store.favorites.collectAsState()
    val scope = rememberCoroutineScope()

    /** Now minus 5 minutes, or the chosen time. */
    fun start() = time ?: (System.currentTimeMillis() - 5 * 60_000)

    suspend fun load(at: Station, from: Long) =
        Kit.board(at, departures, from, WINDOW, products.takeIf { it != Product.all }, ticket.takeIf { onlyValidTicket })

    LaunchedEffect(station, departures, time, products, onlyValidTicket, reload) {
        val at = station ?: return@LaunchedEffect
        // Back from a train: the board shown is fresh enough.
        if (entries != null && reload == 0 && System.currentTimeMillis() - loadedAt < 60_000) delay(60_000 - (System.currentTimeMillis() - loadedAt))
        while (true) {
            error = null
            try {
                entries = load(at, start())
                loadedAt = System.currentTimeMillis()
            } catch (e: Exception) {
                error = e.message ?: "Die Abfahrten konnten nicht geladen werden."
            }
            refreshing = false
            // Live data every minute while showing now.
            if (time != null) break
            delay(60_000)
        }
    }

    fun loadMore(later: Boolean) {
        val at = station ?: return
        val current = entries ?: return
        if (paging) return
        paging = true
        scope.launch {
            val from = if (later) current.maxOfOrNull { it.entry.time.planned } ?: start() else start() - WINDOW * 60_000L
            runCatching { load(at, from) }.onSuccess { page ->
                val ids = current.map { it.id }.toSet()
                entries = (current + page.filter { it.id !in ids }).sortedBy { it.entry.time.best }
            }
            paging = false
        }
    }

    Column(Modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text(station?.shownName ?: "Abfahrten", maxLines = 1) },
            navigationIcon = {
                if (station != null) IconButton(onClick = { board.station = null; entries = null }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Zurück") }
            },
            actions = {
                if (station != null) {
                    val favorite = favorites.any { it.isSamePlace(station) }
                    IconButton(onClick = { model.store.toggleFavorite(station) }) {
                        Icon(if (favorite) Icons.Filled.Star else Icons.Filled.StarBorder, if (favorite) "Aus Favoriten entfernen" else "Zu Favoriten", tint = if (favorite) Gold else MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    IconButton(onClick = { filtering = true }) { Icon(Icons.Filled.FilterList, "Verkehrsmittel") }
                }
                IconButton(onClick = { model.push(Route.TrainSearch) }) { Icon(Icons.Filled.Train, "Zug suchen") }
                IconButton(onClick = { picking = true }) { Icon(Icons.Filled.Search, "Bahnhof suchen") }
            },
        )
        if (station == null) {
            Favorites(favorites, onPick = { board.station = it; entries = null }, onSearch = { picking = true })
        } else {
            Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                    listOf("Abfahrten" to true, "Ankünfte" to false).forEachIndexed { index, (label, value) ->
                        SegmentedButton(departures == value, onClick = { departures = value; entries = null }, shape = SegmentedButtonDefaults.itemShape(index, 2)) { Text(label) }
                    }
                }
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.Center) {
                    TimeSelector(time, onChange = { time = it; entries = null })
                    if (products != Product.all) SuggestionChip(onClick = { filtering = true }, label = { Text(productSummary(products), maxLines = 1) })
                    if (onlyValidTicket) SuggestionChip(onClick = { filtering = true }, label = { Text(ticket.filterTitle, maxLines = 1) })
                    if (loadedAt > 0) Text("Stand ${timeString(loadedAt)}", Modifier.align(Alignment.CenterVertically), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            PullToRefreshBox(isRefreshing = refreshing, onRefresh = { refreshing = true; reload++ }, modifier = Modifier.fillMaxSize()) {
                val list = entries
                when {
                    error != null && list == null -> Message(error!!, "Erneut versuchen") { reload++ }
                    list == null -> Message("Lade …")
                    list.isEmpty() -> Message(if (departures) "Keine Abfahrten" else "Keine Ankünfte")
                    else -> LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        item { PageButton(if (departures) "Frühere Abfahrten" else "Frühere Ankünfte", paging) { loadMore(later = false) } }
                        items(list, key = { it.id }) { entry ->
                            BoardRow(entry) { model.push(Route.TripFromBoard(entry)) }
                            HorizontalDivider()
                        }
                        item { PageButton(if (departures) "Spätere Abfahrten" else "Spätere Ankünfte", paging) { loadMore(later = true) } }
                    }
                }
            }
        }
    }

    if (picking) {
        StationPicker(model.store, "Bahnhof suchen", onPick = { board.station = it; entries = null; picking = false }, onDismiss = { picking = false })
    }
    if (filtering) {
        ProductFilterSheet(
            products,
            onChange = { products = it; entries = null },
            onDismiss = { filtering = false },
            showRegionalShortcut = true,
            ticket = ticket,
            onlyValidTicket = onlyValidTicket,
            onTicketChange = { onlyValidTicket = it; entries = null },
        )
    }
}

@Composable
private fun Favorites(favorites: List<Station>, onPick: (Station) -> Unit, onSearch: () -> Unit) {
    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        OutlinedButton(onClick = onSearch, modifier = Modifier.fillMaxWidth()) {
            Icon(Icons.Filled.Search, null, Modifier.size(18.dp))
            Text("Bahnhof suchen", Modifier.padding(start = 8.dp))
        }
        if (favorites.isEmpty()) {
            Text("Deine Lieblingsbahnhöfe erscheinen hier. Tipp auf den Stern, um einen zu merken.", color = MaterialTheme.colorScheme.onSurfaceVariant)
        } else {
            Text("Favoriten", style = MaterialTheme.typography.titleMedium)
            Card {
                favorites.forEachIndexed { index, station ->
                    if (index > 0) HorizontalDivider()
                    Row(Modifier.fillMaxWidth().clickable { onPick(station) }.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Filled.Star, null, tint = Gold)
                        Text(station.shownName, Modifier.padding(start = 12.dp))
                    }
                }
            }
        }
    }
}

@Composable
private fun PageButton(title: String, loading: Boolean, onClick: () -> Unit) {
    OutlinedButton(onClick = onClick, enabled = !loading, modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
        if (loading) CircularProgressIndicator(Modifier.padding(end = 8.dp).size(16.dp), strokeWidth = 2.dp)
        Text(title)
    }
}

/** Time, line, where it goes or comes from, notes and platform (`BoardRow`). */
@Composable
private fun BoardRow(display: BoardEntryDisplay, onClick: () -> Unit) {
    val entry = display.entry
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Column(Modifier.width(52.dp)) { TimeStack(entry.time, cancelled = entry.cancelled) }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            LineBadge(display.line, small = true)
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (entry.kind == "arrivals") Icon(Icons.AutoMirrored.Filled.ArrowBack, null, Modifier.size(14.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                else Icon(Icons.AutoMirrored.Filled.ArrowForward, null, Modifier.size(14.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(
                    entry.otherEnd ?: "",
                    Modifier.padding(start = 4.dp),
                    fontWeight = FontWeight.Medium,
                    maxLines = 1,
                    textDecoration = if (entry.cancelled) TextDecoration.LineThrough else null,
                )
            }
            when (entry.access) {
                "exitOnly" -> Tag("Nur Ausstieg")
                "entryOnly" -> Tag("Nur Einstieg")
            }
            entry.remarks.firstOrNull()?.let {
                Text(it, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2)
            }
        }
        PlatformBadge(entry.platform)
    }
}
