@file:OptIn(ExperimentalMaterial3Api::class)

package de.goldkunibert.betterbahn.ui.departures

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.filled.BookmarkBorder
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Surface
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import de.goldkunibert.betterbahn.AppModel
import de.goldkunibert.betterbahn.Route
import de.goldkunibert.betterbahn.kit.JourneyDisplay
import de.goldkunibert.betterbahn.kit.Kit
import de.goldkunibert.betterbahn.kit.Station
import de.goldkunibert.betterbahn.kit.Stopover
import de.goldkunibert.betterbahn.kit.TimeInfo
import de.goldkunibert.betterbahn.kit.TripDisplay
import de.goldkunibert.betterbahn.ui.HeavyDelay
import de.goldkunibert.betterbahn.ui.LineBadge
import de.goldkunibert.betterbahn.ui.PlatformBadge
import de.goldkunibert.betterbahn.ui.Tag
import de.goldkunibert.betterbahn.ui.connections.Message
import de.goldkunibert.betterbahn.ui.connections.Remark
import de.goldkunibert.betterbahn.ui.delayColor
import de.goldkunibert.betterbahn.ui.durationString
import de.goldkunibert.betterbahn.ui.lineColor
import de.goldkunibert.betterbahn.ui.timeString

/**
 * A train's whole run (`TripView`): every stop with times, delays and platforms. Tapping stops picks where to get
 * on and off ([boardingAt], [exitAt] at first); the bar below saves that ride. Stops outside it are faded.
 */
@Composable
fun TripScreen(
    model: AppModel,
    boardingAt: Station?,
    exitAt: Station?,
    loaded: TripDisplay? = null,
    load: suspend () -> TripDisplay,
) {
    var display by remember { mutableStateOf(loaded) }
    var error by remember { mutableStateOf<String?>(null) }
    var attempt by remember { mutableIntStateOf(0) }
    var start by remember { mutableStateOf<Int?>(null) }
    var end by remember { mutableStateOf<Int?>(null) }
    var ride by remember { mutableStateOf<JourneyDisplay?>(null) }

    LaunchedEffect(attempt) {
        if (display != null && attempt == 0) return@LaunchedEffect
        error = null
        runCatching { load() }.onSuccess { display = it }.onFailure { error = it.message ?: "Der Fahrtverlauf konnte nicht geladen werden." }
    }
    // The stops the user came from, once the trip is there.
    LaunchedEffect(display != null) {
        val stops = display?.trip?.stopovers ?: return@LaunchedEffect
        if (start != null || end != null) return@LaunchedEffect
        val from = boardingAt?.let { station -> stops.indexOfFirst { it.station.isSamePlace(station) } }?.takeIf { it >= 0 }
        val to = exitAt?.let { station ->
            stops.indices.firstOrNull { it > (from ?: -1) && stops[it].station.isSamePlace(station) }
        }
        start = from
        end = to
    }
    LaunchedEffect(start, end, display) {
        val trip = display
        val from = start
        val to = end
        ride = if (trip != null && from != null && to != null) runCatching { Kit.tripLeg(trip, from, to) }.getOrNull() else null
    }

    fun tap(index: Int) {
        val from = start
        when {
            from == null -> start = index
            index == from -> { start = null; end = null }
            index < from -> start = index
            index == end -> end = null
            else -> end = index
        }
    }

    Column(Modifier.fillMaxSize()) {
        TopAppBar(
            title = {
                val trip = display
                if (trip != null) {
                    Column {
                        Text(trip.line?.nameWithTripNumber ?: trip.trip.line?.name ?: "Fahrt", maxLines = 1)
                        val origin = trip.trip.origin?.shownName
                        val destination = trip.trip.destination?.shownName
                        if (origin != null && destination != null) {
                            Text("$origin → $destination", style = MaterialTheme.typography.bodySmall, maxLines = 1)
                        }
                    }
                } else Text("Fahrtverlauf")
            },
            navigationIcon = { IconButton(onClick = { model.pop() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Zurück") } },
        )
        val trip = display
        when {
            trip == null && error != null -> Message(error!!, "Erneut versuchen") { attempt++ }
            trip == null -> Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                CircularProgressIndicator()
                Text("Lade Fahrtverlauf …", Modifier.padding(top = 12.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            else -> {
                val now = System.currentTimeMillis()
                val stops = trip.trip.stopovers
                val color = trip.line?.let { lineColor(it) } ?: MaterialTheme.colorScheme.primary
                LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(16.dp)) {
                    item {
                        Column(Modifier.padding(bottom = 12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                LineBadge(trip.line)
                                trip.trip.line?.operatorName?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                                if (trip.trip.cancelled) Text("Fällt aus", color = HeavyDelay, fontWeight = FontWeight.Bold)
                            }
                            Text("Tipp auf zwei Halte, um die Fahrt dazwischen zu speichern.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                    itemsIndexed(stops, key = { index, stop -> "$index" + stop.station.id }) { index, stop ->
                        val from = start
                        val to = end
                        val selected = index == from || index == to
                        val outside = if (from != null && to != null) index < from || index > to
                        else (stop.departure ?: stop.arrival)?.best?.let { it < now } == true
                        StopNode(
                            stop = stop,
                            bold = selected,
                            passed = outside,
                            first = index == 0,
                            last = index == stops.lastIndex,
                            lineColor = color,
                            onClick = { tap(index) },
                        )
                    }
                    if (trip.trip.remarks.isNotEmpty() || trip.trip.messages.isNotEmpty()) {
                        item {
                            Column(Modifier.padding(top = 16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                (trip.trip.messages.map { it.text } + trip.trip.remarks).distinct().forEach { Remark(it) }
                            }
                        }
                    }
                }
                ride?.let { RideBar(model, it) }
            }
        }
    }
}

/** "A → B", duration, and saving the picked ride (`SaveJourneyButton`). */
@Composable
private fun RideBar(model: AppModel, ride: JourneyDisplay) {
    val leg = ride.journey.legs.first()
    val saved = model.isSaved(ride)
    Surface(tonalElevation = 3.dp, shadowElevation = 6.dp) {
        Row(Modifier.fillMaxWidth().padding(16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Column(Modifier.weight(1f).clickable { model.push(Route.Detail(ride)) }) {
                Text("${leg.origin.shownName} → ${leg.destination.shownName}", fontWeight = FontWeight.SemiBold, maxLines = 2)
                Text(
                    "${timeString(leg.departure.planned)} – ${timeString(leg.arrival.planned)}" +
                        (ride.durationSeconds?.let { " · ${durationString(it)}" } ?: ""),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Button(onClick = { model.toggleSaved(ride) }) {
                Icon(if (saved) Icons.Filled.Bookmark else Icons.Filled.BookmarkBorder, null, Modifier.size(18.dp))
                Text(if (saved) "Gespeichert" else "Speichern", Modifier.padding(start = 6.dp))
            }
        }
    }
}

@Composable
private fun StopNode(
    stop: Stopover,
    bold: Boolean,
    passed: Boolean,
    first: Boolean,
    last: Boolean,
    lineColor: androidx.compose.ui.graphics.Color,
    onClick: () -> Unit = {},
) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).height(androidx.compose.foundation.layout.IntrinsicSize.Min)
            .alpha(if (passed && !bold) 0.55f else 1f),
    ) {
        Column(Modifier.width(64.dp).padding(vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            stop.arrival?.takeIf { !first }?.let { TimeText(it, stop.arrivalCancelled) }
            stop.departure?.takeIf { !last }?.let { TimeText(it, stop.departureCancelled) }
        }
        // The line through all stops, a dot per stop.
        Box(Modifier.width(24.dp).fillMaxHeight(), contentAlignment = Alignment.Center) {
            Column(Modifier.fillMaxHeight(), horizontalAlignment = Alignment.CenterHorizontally) {
                Box(Modifier.width(4.dp).weight(1f).background(if (first) androidx.compose.ui.graphics.Color.Transparent else lineColor))
                Box(Modifier.width(4.dp).weight(1f).background(if (last) androidx.compose.ui.graphics.Color.Transparent else lineColor))
            }
            Box(Modifier.size(if (bold) 14.dp else 10.dp).background(lineColor, CircleShape))
        }
        Column(Modifier.weight(1f).padding(vertical = 8.dp, horizontal = 8.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(
                stop.station.shownName,
                fontWeight = if (bold) FontWeight.Bold else FontWeight.Normal,
                textDecoration = if (stop.cancelled) TextDecoration.LineThrough else null,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                when (stop.access) {
                    "exitOnly" -> Tag("Nur Ausstieg")
                    "entryOnly" -> Tag("Nur Einstieg")
                }
                if (stop.isAdditional) Tag("Zusatzhalt")
                if (stop.isManual) Tag("Selbst eingetragen")
            }
        }
        Box(Modifier.padding(vertical = 6.dp)) { PlatformBadge(stop.departurePlatform ?: stop.arrivalPlatform) }
    }
}

/** The live time where known, else the planned one, with the delay; "Ausfall" when cancelled (`DelayTimeText`). */
@Composable
private fun TimeText(time: TimeInfo, cancelled: Boolean) {
    Row(horizontalArrangement = Arrangement.spacedBy(3.dp)) {
        Text(
            timeString(time.best),
            style = MaterialTheme.typography.bodyMedium,
            fontWeight = FontWeight.SemiBold,
            textDecoration = if (cancelled) TextDecoration.LineThrough else null,
            color = if (time.actual != null && !cancelled) delayColor(time.delayMinutes) else MaterialTheme.colorScheme.onSurface,
        )
        when {
            cancelled -> Text("Ausfall", style = MaterialTheme.typography.labelSmall, color = HeavyDelay)
            (time.delayMinutes ?: 0) > 0 -> Text("+${time.delayMinutes}", style = MaterialTheme.typography.labelSmall, color = delayColor(time.delayMinutes))
        }
    }
}
