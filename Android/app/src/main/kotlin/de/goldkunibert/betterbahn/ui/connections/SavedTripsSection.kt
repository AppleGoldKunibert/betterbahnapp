package de.goldkunibert.betterbahn.ui.connections

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.CallMade
import androidx.compose.material.icons.filled.SwapHoriz
import androidx.compose.material.icons.filled.Train
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import de.goldkunibert.betterbahn.AppModel
import de.goldkunibert.betterbahn.Route
import de.goldkunibert.betterbahn.data.SavedJourney
import de.goldkunibert.betterbahn.kit.JourneyDisplay
import de.goldkunibert.betterbahn.kit.Kit
import de.goldkunibert.betterbahn.kit.Leg
import de.goldkunibert.betterbahn.kit.LiveStatus
import de.goldkunibert.betterbahn.kit.PlatformInfo
import de.goldkunibert.betterbahn.kit.TimeInfo
import de.goldkunibert.betterbahn.ui.DesignCard
import de.goldkunibert.betterbahn.ui.HeavyDelay
import de.goldkunibert.betterbahn.ui.Punctual
import de.goldkunibert.betterbahn.ui.Ticket
import de.goldkunibert.betterbahn.ui.TicketCaption
import de.goldkunibert.betterbahn.ui.dayLabel
import de.goldkunibert.betterbahn.ui.delayColor
import de.goldkunibert.betterbahn.ui.isFahrkarte
import de.goldkunibert.betterbahn.ui.timeString
import de.goldkunibert.betterbahn.ui.transferColor
import kotlinx.coroutines.delay
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject

/**
 * "Deine Reisen" below the search: the saved journeys not over yet, each with what comes next live
 * (`UpcomingTripsSection` / `TripTicketsSection` on iOS). Updated every minute.
 */
@Composable
fun SavedTripsSection(model: AppModel) {
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(60_000 - now % 60_000)
            now = System.currentTimeMillis()
        }
    }
    val upcoming = model.saved
        .mapNotNull { entry -> model.savedDisplays[entry.id]?.let { entry to it } }
        .filter { (_, display) -> (display.journey.arrival?.best ?: 0) > now }
        .sortedBy { (_, display) -> display.journey.departure?.planned ?: Long.MAX_VALUE }

    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        SectionTitle("Deine Reisen")
        if (upcoming.isEmpty()) {
            Text(
                "Hier erscheinen deine gespeicherten Reisen.", Modifier.padding(horizontal = 4.dp),
                style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        upcoming.forEachIndexed { index, (entry, display) ->
            SavedTrip(entry, display, now, isNext = index == 0) { model.push(Route.Detail(display)) }
        }
    }
}

/** Minimal: a title with an icon. Fahrkarte: a bold title (`SectionHeader`). */
@Composable
fun SectionTitle(title: String, trailing: String? = null, modifier: Modifier = Modifier) {
    Row(modifier.fillMaxWidth().padding(horizontal = 4.dp, vertical = 2.dp), verticalAlignment = Alignment.Bottom) {
        Text(
            title, Modifier.weight(1f),
            style = if (isFahrkarte) MaterialTheme.typography.titleLarge else MaterialTheme.typography.titleMedium,
            fontWeight = if (isFahrkarte) FontWeight.Bold else FontWeight.SemiBold,
        )
        trailing?.let { Text(it, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant) }
    }
}

@Composable
private fun SavedTrip(entry: SavedJourney, display: JourneyDisplay, now: Long, isNext: Boolean, onOpen: () -> Unit) {
    val journey = display.journey
    var status by remember(entry.id) { mutableStateOf<LiveStatus?>(null) }
    var series by remember(entry.id) { mutableStateOf<List<String>>(emptyList()) }
    LaunchedEffect(display, now) { status = runCatching { Kit.liveStatus(display.raw, now) }.getOrNull() }
    // The trains still ahead: a finished ride drops out.
    val upcoming = status?.upcomingIndices ?: journey.legs.indices.filter { !journey.legs[it].isWalking }
    LaunchedEffect(display.id, upcoming) {
        val legs = display.raw["legs"]?.jsonArray ?: return@LaunchedEffect
        series = runCatching { Kit.trainSeries(upcoming.mapNotNull { legs.getOrNull(it)?.jsonObject }) }.getOrDefault(emptyList())
    }
    val first = journey.legs.firstOrNull()
    val last = journey.legs.lastOrNull()
    val day = journey.departure?.planned?.let(::dayLabel).orEmpty()

    val header: @Composable () -> Unit = {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(day.uppercase(), style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.width(8.dp).weight(1f))
            if (series.isNotEmpty()) {
                Text(series.joinToString(" · "), style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
    val route: @Composable () -> Unit = {
        if (first != null && last != null) {
            Text("${first.origin.shownName} → ${last.destination.shownName}", style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
    val live: @Composable () -> Unit = {
        status?.let { LiveLines(journey.legs, it, now) }
        display.issues.firstOrNull { it.isBlocking }?.let { issue ->
            LiveRow(Icons.Filled.Warning, issue.title, null, HeavyDelay, null)
        }
    }

    if (isFahrkarte) {
        Ticket(Modifier.clickable(onClick = onOpen), sections = listOf(
            { Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) { header(); route() } },
            { Column(Modifier.padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) { live() } },
        ))
    } else {
        DesignCard(Modifier.clickable(onClick = onOpen)) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                header()
                route()
                live()
            }
        }
    }
}

/**
 * One or two lines of what comes next: the departure, the train being ridden or the transfer underway, then the
 * change after it (ConnectionsTicketViews.swift `liveLines`).
 */
@Composable
private fun LiveLines(legs: List<Leg>, status: LiveStatus, now: Long) {
    val leg = legs.getOrNull(status.legIndex) ?: return
    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
        when (status.step) {
            "departure" ->
                if (leg.cancelled) LiveRow(Icons.AutoMirrored.Filled.CallMade, lineName(leg), "Fällt aus", HeavyDelay, null)
                else LiveRow(Icons.AutoMirrored.Filled.CallMade, lineName(leg), whenText(leg.departure.best, now), liveColor(leg.departure), platform(leg.departurePlatform))
            "riding" -> LiveRow(
                Icons.Filled.Train, "${lineName(leg)} bis ${leg.destination.shownName}", "an ${timeString(leg.arrival.best)}",
                liveColor(leg.arrival), platform(leg.arrivalPlatform),
            )
            else -> LiveRow(
                Icons.Filled.SwapHoriz, "Umstieg in ${leg.origin.shownName} · ${lineName(leg)}",
                if (leg.cancelled) "Fällt aus" else whenText(leg.departure.best, now),
                if (leg.cancelled) HeavyDelay else liveColor(leg.departure), platform(leg.departurePlatform),
            )
        }
        // Shown from 10 minutes before the arrival.
        status.nextTransfer?.let { transfer ->
            val next = legs.getOrNull(transfer.nextIndex) ?: return@let
            if (transfer.isMissed || next.cancelled) {
                LiveRow(Icons.Filled.Warning, next.origin.shownName, "Anschluss nicht erreichbar", HeavyDelay, null)
            } else {
                LiveRow(
                    Icons.Filled.SwapHoriz, "Dann Umstieg in ${next.origin.shownName} · ${lineName(next)}",
                    if (transfer.waiting) transfer.waitingTitle else "${transfer.minutes} Min.",
                    if (transfer.waiting) Punctual else transferColor(transfer.minutes), platform(next.departurePlatform),
                )
            }
        }
    }
}

/** Icon, what happens, then the time coloured by its delay and the platform (`liveRow`). */
@Composable
private fun LiveRow(icon: ImageVector, main: String, time: String?, timeColor: Color, platform: String?) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Icon(icon, null, Modifier.size(14.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(main, Modifier.weight(1f, fill = false), style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
        time?.let {
            Text("·", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.outline)
            Text(it, style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.SemiBold, color = timeColor, maxLines = 1)
        }
        platform?.let {
            Text("·", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.outline)
            Text(it, style = MaterialTheme.typography.bodySmall, maxLines = 1)
        }
    }
}

/** Green on time, orange or red when late; plain without live data. */
@Composable
private fun liveColor(time: TimeInfo): Color = if (time.actual == null) MaterialTheme.colorScheme.onSurface else delayColor(time.delayMinutes)

private fun lineName(leg: Leg): String = leg.line?.name ?: "Zug"

private fun platform(info: PlatformInfo?): String? = info?.best?.let { "Gleis $it" }

/** "in 12 Min." within the hour, else "ab 15:20" (`when`). */
private fun whenText(time: Long, now: Long): String {
    val minutes = Math.floorDiv(time - now, 60_000L)
    return if (minutes in 0..60) "in $minutes Min." else "ab ${timeString(time)}"
}
