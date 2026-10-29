@file:OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)

package de.goldkunibert.betterbahn.ui.connections

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.DirectionsWalk
import androidx.compose.material.icons.filled.AcUnit
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.Eco
import androidx.compose.material.icons.filled.NightsStay
import androidx.compose.material.icons.filled.Thunderstorm
import androidx.compose.material.icons.filled.Umbrella
import androidx.compose.material.icons.filled.WbSunny
import androidx.compose.material.icons.filled.BookmarkBorder
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.SyncAlt
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import de.goldkunibert.betterbahn.AppModel
import de.goldkunibert.betterbahn.Route
import de.goldkunibert.betterbahn.data.ConnectionSearch
import de.goldkunibert.betterbahn.kit.ArrivalWeather
import de.goldkunibert.betterbahn.kit.JourneyDisplay
import de.goldkunibert.betterbahn.kit.JourneyExtras
import de.goldkunibert.betterbahn.kit.Kit
import de.goldkunibert.betterbahn.kit.Leg
import de.goldkunibert.betterbahn.kit.LegDisplay
import de.goldkunibert.betterbahn.kit.Stopover
import de.goldkunibert.betterbahn.ui.DelayPill
import de.goldkunibert.betterbahn.ui.HeavyDelay
import de.goldkunibert.betterbahn.ui.LineBadge
import de.goldkunibert.betterbahn.ui.PlatformBadge
import de.goldkunibert.betterbahn.ui.Punctual
import de.goldkunibert.betterbahn.ui.SegmentBar
import de.goldkunibert.betterbahn.ui.SlightDelay
import de.goldkunibert.betterbahn.ui.Tag
import de.goldkunibert.betterbahn.ui.TimeStack
import de.goldkunibert.betterbahn.ui.dayLabel
import de.goldkunibert.betterbahn.ui.delayColor
import de.goldkunibert.betterbahn.ui.durationString
import de.goldkunibert.betterbahn.ui.timeString
import de.goldkunibert.betterbahn.ui.transferColor
import de.goldkunibert.betterbahn.ui.transfersText
import kotlinx.coroutines.delay
import kotlin.math.roundToInt

/** How often an open journey reloads its live data (`AppModel.realtimeRefreshInterval`). */
private const val REFRESH_MILLIS = 300_000L

/**
 * A connection in full (`JourneyDetailView`): summary with "Speichern", what's wrong, each train with its stops,
 * the transfers in between. Loads the stops and platforms the feeds leave out, then live data, every 5 minutes.
 */
@Composable
fun JourneyDetailScreen(model: AppModel, route: Route.Detail) {
    var display by route::journey
    var loadingLive by remember { mutableStateOf(true) }
    var extras by remember { mutableStateOf(JourneyExtras()) }
    val saved = model.isSaved(display)

    // CO₂ and weather; again when live data moves an arrival (the forecasts are cached).
    LaunchedEffect(display.id, display.journey.arrival?.best) {
        runCatching { Kit.journeyExtras(display.raw) }.onSuccess { extras = it }
    }

    LaunchedEffect(route) {
        if (!route.completed) {
            runCatching { Kit.completeJourney(display.raw) }.onSuccess { display = it }
            route.completed = true
        }
        while (true) {
            if (!display.isOver) {
                loadingLive = true
                runCatching { Kit.refreshJourney(display.raw) }.onSuccess { fresh ->
                    if (model.isSaved(display)) model.updateSaved(display, fresh)
                    display = fresh
                }
            }
            loadingLive = false
            delay(REFRESH_MILLIS)
        }
    }

    Column(Modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text("Reiseplan") },
            navigationIcon = { IconButton(onClick = { model.pop() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Zurück") } },
            actions = {
                if (loadingLive) CircularProgressIndicator(Modifier.size(20.dp).padding(end = 4.dp), strokeWidth = 2.dp)
                IconButton(onClick = { model.toggleSaved(display) }) {
                    Icon(if (saved) Icons.Filled.Bookmark else Icons.Filled.BookmarkBorder, if (saved) "Gespeichert" else "Speichern")
                }
            },
        )
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Summary(display, extras, saved) { model.toggleSaved(display) }
            if (display.issues.isNotEmpty()) {
                Issues(display) { alternativeSearch(display)?.let { model.push(Route.Results(it)) } }
            }
            Legs(display, extras) { index -> model.push(Route.TripFromLeg(display, index)) }
            Spacer(Modifier.height(24.dp))
        }
    }
}

@Composable
private fun Summary(display: JourneyDisplay, extras: JourneyExtras, saved: Boolean, onSave: () -> Unit) {
    val journey = display.journey
    Card {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            journey.departure?.let { Text(dayLabel(it.planned, long = true), style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            Row(verticalAlignment = Alignment.Top) {
                Column(Modifier.weight(1f)) {
                    journey.departure?.let { TimeStack(it, cancelled = display.isCancelled) }
                    Text(journey.legs.first().origin.shownName, style = MaterialTheme.typography.bodyMedium)
                }
                Column(Modifier.weight(1f), horizontalAlignment = Alignment.End) {
                    journey.arrival?.let { TimeStack(it, cancelled = display.isCancelled, alignEnd = true) }
                    Text(journey.legs.last().destination.shownName, style = MaterialTheme.typography.bodyMedium)
                }
            }
            SegmentBar(display, Modifier.fillMaxWidth().height(8.dp))
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                display.durationSeconds?.let { AssistChip(onClick = {}, label = { Text(durationString(it)) }) }
                AssistChip(onClick = {}, label = { Text(transfersText(display.transfers)) })
                if (extras.co2SavedKilograms >= 0.1) {
                    AssistChip(
                        onClick = {},
                        label = { Text("−${kilograms(extras.co2SavedKilograms)} CO₂") },
                        leadingIcon = { Icon(Icons.Filled.Eco, "weniger als mit dem Auto", Modifier.size(18.dp), tint = Punctual) },
                    )
                }
            }
            FilledTonalButton(onClick = onSave, modifier = Modifier.fillMaxWidth()) {
                Icon(if (saved) Icons.Filled.Bookmark else Icons.Filled.BookmarkBorder, null, Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text(if (saved) "Gespeichert" else "Speichern")
            }
        }
    }
}

/**
 * A new search from where the journey breaks (`AlternativeJourneySheet`): from the station of the transfer that no
 * longer works at the arrival there, or from the start of the first cancelled train; to the same destination.
 */
private fun alternativeSearch(display: JourneyDisplay): ConnectionSearch? {
    val journey = display.journey
    val destination = journey.legs.lastOrNull()?.destination ?: return null
    val transit = journey.transitLegs
    val broken = display.brokenTransferIndices.firstOrNull()?.let { transit.getOrNull(it - 1) }
    val cancelled = transit.firstOrNull { it.cancelled }
    return when {
        broken != null -> ConnectionSearch(broken.destination, destination, date = broken.arrival.best)
        cancelled != null -> ConnectionSearch(cancelled.origin, destination, date = cancelled.departure.planned)
        else -> {
            // A transfer too tight to make: from where the earlier train arrives.
            val tight = (1 until transit.size).firstOrNull { transit[it].departure.best - transit[it - 1].arrival.best < 2 * 60_000 }
                ?.let { transit[it - 1] }
            tight?.let { ConnectionSearch(it.destination, destination, date = it.arrival.best) }
        }
    }
}

@Composable
private fun Issues(display: JourneyDisplay, onAlternative: () -> Unit) {
    Card(colors = CardDefaults.cardColors(containerColor = HeavyDelay.copy(alpha = 0.10f))) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            for (issue in display.issues) {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Icon(Icons.Filled.Warning, null, tint = if (issue.isBlocking) HeavyDelay else SlightDelay)
                    Column {
                        Text(issue.title, fontWeight = FontWeight.SemiBold)
                        Text(issue.message, style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
            if (display.issues.any { it.isBlocking } && alternativeSearch(display) != null) {
                FilledTonalButton(onClick = onAlternative, modifier = Modifier.fillMaxWidth()) { Text("Alternative suchen") }
            }
        }
    }
}

/** The trains as cards; walks and waiting times go into the transfer between them. */
@Composable
private fun Legs(display: JourneyDisplay, extras: JourneyExtras, onOpenTrain: (Int) -> Unit) {
    val legs = display.journey.legs
    val transit = legs.indices.filter { !legs[it].isWalking }
    if (transit.isEmpty()) {
        // Only a walk.
        legs.firstOrNull()?.let { Text("${durationMinutes(it)} min Fußweg zu ${it.destination.shownName}") }
        return
    }
    legs.indices.filter { it < transit.first() }.forEach { WalkNote(legs[it]) }
    transit.forEachIndexed { position, index ->
        if (position > 0) {
            val previous = transit[position - 1]
            Transfer(
                arriving = legs[previous],
                departing = legs[index],
                walks = (previous + 1 until index).map { legs[it] },
                broken = position in display.brokenTransferIndices,
            )
        }
        LegCard(legs[index], display.legs[index], extras.arrivalWeather[index.toString()]) { onOpenTrain(index) }
    }
    legs.indices.filter { it > transit.last() }.forEach { WalkNote(legs[it]) }
}

private fun durationMinutes(leg: Leg) = ((leg.arrival.planned - leg.departure.planned) / 60_000.0).roundToInt()

@Composable
private fun WalkNote(leg: Leg) {
    Row(Modifier.padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Icon(Icons.AutoMirrored.Filled.DirectionsWalk, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Text("${durationMinutes(leg)} min Fußweg zu ${leg.destination.shownName}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** "Umstieg · n min", coloured by how comfortable it is; walks and platforms (`TransferRow`). */
@Composable
private fun Transfer(arriving: Leg, departing: Leg, walks: List<Leg>, broken: Boolean) {
    val minutes = ((departing.departure.best - arriving.arrival.best) / 60_000.0).roundToInt()
    val color = if (minutes < 0) HeavyDelay else transferColor(minutes)
    Column(Modifier.padding(horizontal = 8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(Icons.Filled.SyncAlt, null, tint = color)
            Text(if (minutes < 0) "Umstieg nicht erreichbar" else "Umstieg · $minutes min", color = color, fontWeight = FontWeight.SemiBold)
            val from = arriving.arrivalPlatform?.best
            val to = departing.departurePlatform?.best
            if (from != null && to != null) {
                Text("Gleis $from → $to", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        for (walk in walks) {
            Text("${durationMinutes(walk)} min Fußweg", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (broken) {
            Text("Wegen Verspätung klappt dieser Umstieg nicht mehr.", style = MaterialTheme.typography.bodySmall, color = HeavyDelay)
        }
    }
}

/** One train: line, direction, delay; departure, the stops in between (folded), arrival; notes (`LegCard`). */
@Composable
private fun LegCard(leg: Leg, extra: LegDisplay, weather: ArrivalWeather?, onOpenTrain: () -> Unit) {
    var showStops by remember { mutableStateOf(false) }
    Card {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(Modifier.fillMaxWidth().clickable(onClick = onOpenTrain), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                LineBadge(extra.line)
                Column(Modifier.weight(1f)) {
                    (extra.direction ?: leg.direction)?.let {
                        Text("Richtung $it", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2)
                    }
                    leg.line?.operatorName?.let {
                        Text(it, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
                    }
                }
                if (leg.cancelled) Text("Fällt aus", color = HeavyDelay, fontWeight = FontWeight.Bold, style = MaterialTheme.typography.labelMedium)
                else DelayPill(leg.departure.delayMinutes)
            }
            StopRow(leg.departure.let { it }, leg.origin.shownName, leg.cancelled, platform = { PlatformBadge(leg.departurePlatform, prominent = true) })
            val stops = extra.intermediateStops
            if (stops.isNotEmpty()) {
                Row(
                    Modifier.fillMaxWidth().clickable { showStops = !showStops }.padding(start = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    val count = if (stops.size == 1) "1 Zwischenhalt" else "${stops.size} Zwischenhalte"
                    Text("$count · ${durationString((leg.arrival.planned - leg.departure.planned) / 1000.0)}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Icon(if (showStops) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                AnimatedVisibility(showStops) {
                    Column(Modifier.padding(start = 12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        stops.forEach { IntermediateStop(it) }
                    }
                }
            } else {
                Text(durationString((leg.arrival.planned - leg.departure.planned) / 1000.0), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            StopRow(leg.arrival, leg.destination.shownName, leg.cancelled, note = extra.exitSide, weather = weather, platform = { PlatformBadge(leg.arrivalPlatform, prominent = true) })
            if (leg.remarks.isNotEmpty() || leg.messages.isNotEmpty()) {
                HorizontalDivider()
                (leg.messages.map { it.text } + leg.remarks).distinct().forEach { Remark(it) }
            }
        }
    }
}

@Composable
private fun StopRow(
    time: de.goldkunibert.betterbahn.kit.TimeInfo,
    name: String,
    cancelled: Boolean,
    note: String? = null,
    weather: ArrivalWeather? = null,
    platform: @Composable () -> Unit,
) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Column(Modifier.width(56.dp)) { TimeStack(time, cancelled = cancelled) }
        Column(Modifier.weight(1f)) {
            Text(name, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Medium)
            note?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            weather?.let {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    Icon(weatherIcon(it), null, Modifier.size(14.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text("${it.temperature} · ${it.condition}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
        platform()
    }
}

@Composable
private fun IntermediateStop(stop: Stopover) {
    val time = stop.departure ?: stop.arrival
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            time?.let { timeString(it.best) } ?: "",
            Modifier.width(44.dp),
            style = MaterialTheme.typography.bodySmall,
            textDecoration = if (stop.cancelled) TextDecoration.LineThrough else null,
        )
        time?.delayMinutes?.takeIf { it > 0 }?.let {
            Text("(+$it)", style = MaterialTheme.typography.labelSmall, color = delayColor(it))
        }
        Text(
            stop.station.shownName,
            Modifier.weight(1f),
            style = MaterialTheme.typography.bodySmall,
            textDecoration = if (stop.cancelled) TextDecoration.LineThrough else null,
        )
        if (stop.isAdditional) Tag("Zusatzhalt")
    }
}

@Composable
fun Remark(text: String) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Icon(Icons.Filled.Info, null, Modifier.size(16.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(text, style = MaterialTheme.typography.bodySmall)
    }
}

/** "3,2 kg", whole kilograms from 10 on (`CO2Comparison.kilogramsText`). */
private fun kilograms(value: Double): String =
    if (value < 10) "%.1f kg".format(java.util.Locale.GERMANY, value) else "%.0f kg".format(java.util.Locale.GERMANY, value)

/** WMO weather codes as Open-Meteo gives them. */
private fun weatherIcon(weather: ArrivalWeather) = when (weather.weatherCode) {
    0, 1 -> if (weather.isDay) Icons.Filled.WbSunny else Icons.Filled.NightsStay
    in 51..67, in 80..82 -> Icons.Filled.Umbrella
    in 71..77, 85, 86 -> Icons.Filled.AcUnit
    in 95..99 -> Icons.Filled.Thunderstorm
    else -> Icons.Filled.Cloud
}
