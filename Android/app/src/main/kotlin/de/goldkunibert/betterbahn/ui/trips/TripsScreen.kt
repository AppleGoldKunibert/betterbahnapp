@file:OptIn(ExperimentalMaterial3Api::class)

package de.goldkunibert.betterbahn.ui.trips

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.History
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import de.goldkunibert.betterbahn.AppModel
import de.goldkunibert.betterbahn.Route
import de.goldkunibert.betterbahn.data.SavedJourney
import de.goldkunibert.betterbahn.kit.JourneyDisplay
import de.goldkunibert.betterbahn.ui.Brand
import de.goldkunibert.betterbahn.ui.HeavyDelay
import de.goldkunibert.betterbahn.ui.JourneyCard
import de.goldkunibert.betterbahn.ui.connections.Message
import de.goldkunibert.betterbahn.ui.dayLabel
import kotlinx.coroutines.delay

/** Saved journeys ("Reisen", `TripsView`): upcoming ones with live data, every 5 minutes; past ones apart. */
@Composable
fun TripsScreen(model: AppModel) {
    val saved by model.store.savedJourneys.collectAsState()
    LaunchedEffect(Unit) {
        while (true) {
            model.refreshSaved()
            delay(300_000)
        }
    }
    val upcoming = saved.filter { entry -> model.savedDisplays[entry.id]?.let { !it.isOver } ?: true }
    val pastCount = saved.count { entry -> model.savedDisplays[entry.id]?.isOver == true }

    Column(Modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text("Deine Reisen") },
            actions = {
                if (pastCount > 0) TextButton(onClick = { model.push(Route.PastTrips) }) {
                    Icon(Icons.Filled.History, null)
                    Text("Vergangene Fahrten", Modifier.padding(start = 6.dp))
                }
            },
        )
        PullToRefreshBox(isRefreshing = model.refreshingSaved, onRefresh = { model.refreshSaved() }, modifier = Modifier.fillMaxSize()) {
            if (upcoming.isEmpty()) {
                Message("Hier erscheinen deine gespeicherten Reisen.")
            } else {
                SavedList(model, upcoming, nextHighlight = true)
            }
        }
    }
}

/** Journeys that are over, newest first. */
@Composable
fun PastTripsScreen(model: AppModel) {
    val saved by model.store.savedJourneys.collectAsState()
    val past = saved.filter { entry -> model.savedDisplays[entry.id]?.let { it.isOver } == true }.reversed()
    Column(Modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text("Vergangene Fahrten") },
            navigationIcon = { IconButton(onClick = { model.pop() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Zurück") } },
        )
        if (past.isEmpty()) Message("Noch keine vergangenen Fahrten.") else SavedList(model, past, nextHighlight = false)
    }
}

@Composable
private fun SavedList(model: AppModel, entries: List<SavedJourney>, nextHighlight: Boolean) {
    val now = System.currentTimeMillis()
    val next = if (nextHighlight) entries.firstOrNull { e ->
        model.savedDisplays[e.id]?.journey?.departure?.planned?.let { it - now < 24 * 3600_000L } == true
    }?.id else null
    LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        items(entries, key = { it.id }) { entry ->
            val display = model.savedDisplays[entry.id] ?: return@items
            SavedRow(entry, display, highlight = entry.id == next, onOpen = { model.push(Route.Detail(display)) }, onDelete = { model.deleteSaved(entry.id) })
        }
    }
}

@Composable
private fun SavedRow(entry: SavedJourney, display: JourneyDisplay, highlight: Boolean, onOpen: () -> Unit, onDelete: () -> Unit) {
    val blocking = display.issues.firstOrNull { it.isBlocking }
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                display.journey.departure?.let {
                    Text(dayLabel(it.planned, long = true), style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                val origin = display.journey.legs.firstOrNull()?.origin?.shownName
                val destination = display.journey.legs.lastOrNull()?.destination?.shownName
                if (origin != null && destination != null) Text("$origin → $destination", fontWeight = FontWeight.SemiBold)
            }
            IconButton(onClick = onDelete) { Icon(Icons.Filled.Delete, "Reise löschen", tint = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
        JourneyCard(
            display,
            highlight = when {
                blocking != null -> HeavyDelay
                highlight -> Brand
                else -> null
            },
            onClick = onOpen,
        )
        blocking?.let { Text(it.title, color = HeavyDelay, style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.SemiBold) }
    }
}
