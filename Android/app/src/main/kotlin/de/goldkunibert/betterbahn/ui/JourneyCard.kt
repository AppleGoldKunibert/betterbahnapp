@file:OptIn(ExperimentalLayoutApi::class)

package de.goldkunibert.betterbahn.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Card
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import de.goldkunibert.betterbahn.kit.JourneyDisplay

/** What a journey's row says on the right, first match wins (`JourneyCard` on iOS). */
private sealed interface CardStatus {
    data class Label(val text: String, val color: Color) : CardStatus
    data class Warning(val color: Color) : CardStatus
}

private fun status(display: JourneyDisplay): CardStatus? {
    val transit = display.journey.transitLegs
    return when {
        display.isCancelled -> CardStatus.Label("Fällt aus", HeavyDelay)
        transit.firstOrNull()?.stopovers?.firstOrNull()?.allowsBoarding == false -> CardStatus.Label("Kein Einstieg", HeavyDelay)
        transit.lastOrNull()?.stopovers?.lastOrNull()?.allowsAlighting == false -> CardStatus.Label("Kein Ausstieg", HeavyDelay)
        display.issues.any { it.isBlocking } -> CardStatus.Label("Nicht möglich", HeavyDelay)
        display.issues.isNotEmpty() -> CardStatus.Label("Knapp", SlightDelay)
        display.legs.any { it.hasDelayReason } -> CardStatus.Warning(HeavyDelay)
        display.journey.legs.any { it.remarks.isNotEmpty() || it.messages.isNotEmpty() } -> CardStatus.Warning(SlightDelay)
        else -> null
    }
}

/** A connection in a list: times, duration, the trains, transfers, first platform and what's wrong. */
@Composable
fun JourneyCard(display: JourneyDisplay, modifier: Modifier = Modifier, highlight: Color? = null, onClick: () -> Unit) {
    val journey = display.journey
    Card(onClick = onClick, modifier = modifier.fillMaxWidth(), border = highlight?.let { BorderStroke(2.dp, it) }) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.Top) {
                journey.departure?.let { TimeStack(it, cancelled = display.isCancelled) }
                Column(Modifier.weight(1f).padding(horizontal = 8.dp, vertical = 4.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    display.durationSeconds?.let {
                        Text(compactDuration(it), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    SegmentBar(display, Modifier.padding(top = 6.dp).fillMaxWidth().height(6.dp))
                }
                journey.arrival?.let { TimeStack(it, cancelled = display.isCancelled, alignEnd = true) }
            }
            FlowRow(horizontalArrangement = Arrangement.spacedBy(2.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                val transit = journey.legs.indices.filter { !journey.legs[it].isWalking }
                transit.forEachIndexed { position, index ->
                    if (position > 0) {
                        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, Modifier.size(18.dp).align(Alignment.CenterVertically), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    LineBadge(display.legs[index].line, small = true, modifier = Modifier.align(Alignment.CenterVertically))
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(transfersText(display.transfers), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                journey.transitLegs.firstOrNull()?.departurePlatform?.let { platform ->
                    platform.best?.let {
                        Text(
                            "Gleis $it",
                            style = MaterialTheme.typography.bodySmall,
                            fontWeight = if (platform.hasChanged) FontWeight.Bold else null,
                            color = if (platform.hasChanged) HeavyDelay else MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
                Row(Modifier.weight(1f), horizontalArrangement = Arrangement.End) {
                    when (val status = status(display)) {
                        is CardStatus.Label -> Text(status.text, style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.Bold, color = status.color)
                        is CardStatus.Warning -> Icon(Icons.Filled.Warning, "Hinweise", Modifier.size(18.dp), tint = status.color)
                        null -> {}
                    }
                }
            }
        }
    }
}

/** Each leg on the journey's time bar, in its line's colour; walks as a thin grey line (`JourneySegmentBar`). */
@Composable
fun SegmentBar(display: JourneyDisplay, modifier: Modifier = Modifier) {
    val spans = display.barSpans
    if (spans.isEmpty()) return
    val colors = display.legs.map { leg -> leg.line?.let { lineColor(it) } }
    val walk = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f)
    Canvas(modifier) {
        val start = spans.first()[0]
        val total = (spans.last()[1] - start).coerceAtLeast(1).toFloat()
        spans.forEachIndexed { index, span ->
            val x = (span[0] - start) / total * size.width
            val width = ((span[1] - span[0]) / total * size.width).coerceAtLeast(3f)
            val color = colors.getOrNull(index)
            if (color == null) {
                drawRect(walk, Offset(x, size.height / 2 - 1f), Size(width, 2f))
            } else {
                drawRoundRect(color, Offset(x + 1f, 0f), Size((width - 2f).coerceAtLeast(2f), size.height), CornerRadius(size.height / 2))
            }
        }
    }
}
