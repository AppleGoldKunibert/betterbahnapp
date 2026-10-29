@file:OptIn(ExperimentalMaterial3Api::class)

package de.goldkunibert.betterbahn.ui.departures

import androidx.compose.foundation.background
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
import androidx.compose.material3.CircularProgressIndicator
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
import de.goldkunibert.betterbahn.ui.lineColor
import de.goldkunibert.betterbahn.ui.timeString

/**
 * A train's whole run (`TripView`): every stop with times, delays and platforms. The stations the user came from
 * ([highlighted], the board's station or the leg's ends) are bold, passed stops faded.
 */
@Composable
fun TripScreen(model: AppModel, highlighted: List<Station>, load: suspend () -> TripDisplay) {
    var display by remember { mutableStateOf<TripDisplay?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var attempt by remember { mutableIntStateOf(0) }

    LaunchedEffect(attempt) {
        error = null
        runCatching { load() }.onSuccess { display = it }.onFailure { error = it.message ?: "Der Fahrtverlauf konnte nicht geladen werden." }
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
                LazyColumn(contentPadding = PaddingValues(16.dp)) {
                    item {
                        Row(Modifier.padding(bottom = 12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            LineBadge(trip.line)
                            trip.trip.line?.operatorName?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                            if (trip.trip.cancelled) Text("Fällt aus", color = HeavyDelay, fontWeight = FontWeight.Bold)
                        }
                    }
                    itemsIndexed(stops, key = { index, stop -> "$index" + stop.station.id }) { index, stop ->
                        val passed = (stop.departure ?: stop.arrival)?.best?.let { it < now } == true
                        StopNode(
                            stop = stop,
                            bold = highlighted.any { it.isSamePlace(stop.station) },
                            passed = passed,
                            first = index == 0,
                            last = index == stops.lastIndex,
                            lineColor = color,
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
            }
        }
    }
}

@Composable
private fun StopNode(stop: Stopover, bold: Boolean, passed: Boolean, first: Boolean, last: Boolean, lineColor: androidx.compose.ui.graphics.Color) {
    Row(Modifier.fillMaxWidth().height(androidx.compose.foundation.layout.IntrinsicSize.Min).alpha(if (passed && !bold) 0.55f else 1f)) {
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
