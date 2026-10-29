package de.goldkunibert.betterbahn.widget

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.GlanceTheme
import androidx.glance.action.actionStartActivity
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.appwidget.updateAll
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.padding
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextDecoration
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import de.goldkunibert.betterbahn.MainActivity
import de.goldkunibert.betterbahn.data.Store
import de.goldkunibert.betterbahn.kit.Kit
import de.goldkunibert.betterbahn.kit.WidgetState
import de.goldkunibert.betterbahn.ui.timeString

/**
 * "Reiseübersicht" (`JourneyOverviewWidget` on iOS): the next saved journey's next step (departure, next stop or
 * transfer) with time, delay and platform, and the destination. Updated with the saved journeys' live data.
 */
class JourneyWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        Kit.start(context)
        val saved = Store.get(context).savedJourneys.value
        val state = if (saved.isEmpty()) null else runCatching { Kit.widgetState(saved.map { it.journey }) }.getOrNull()
        provideContent {
            GlanceTheme { Content(state) }
        }
    }

    companion object {
        /** After saving, deleting or refreshing journeys. */
        suspend fun update(context: Context) = JourneyWidget().updateAll(context)
    }
}

class JourneyWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = JourneyWidget()
}

private val Punctual = Color(0xFF219E59)
private val SlightDelay = Color(0xFFF28C0D)
private val HeavyDelay = Color(0xFFE02633)

private fun delayColor(minutes: Int) = when {
    minutes > 10 -> HeavyDelay
    minutes > 5 -> SlightDelay
    else -> Punctual
}

@Composable
private fun Content(state: WidgetState?) {
    val secondary = GlanceTheme.colors.onSurfaceVariant
    Column(
        GlanceModifier.fillMaxSize().background(GlanceTheme.colors.widgetBackground).cornerRadius(16.dp).padding(12.dp)
            .clickable(actionStartActivity<MainActivity>()),
    ) {
        if (state == null) {
            Text("Keine Reise geplant", style = TextStyle(fontWeight = FontWeight.Bold, color = GlanceTheme.colors.onSurface))
            Text("Speichere eine Verbindung, um sie hier zu sehen.", style = TextStyle(fontSize = 12.sp, color = secondary))
            return@Column
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                if (state.phase == "transfer") state.transferTrain ?: state.trainName else state.trainName,
                style = TextStyle(fontWeight = FontWeight.Bold, color = GlanceTheme.colors.onSurface),
            )
            Spacer(GlanceModifier.width(8.dp))
            when {
                state.cancelled -> Text("Fällt aus", style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.Bold, color = ColorProvider(HeavyDelay)))
                state.nextStopDelayMinutes != null -> {
                    val minutes = state.nextStopDelayMinutes
                    Text(if (minutes > 0) "+$minutes" else "pünktlich", style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.Bold, color = ColorProvider(delayColor(minutes))))
                }
            }
        }
        Spacer(GlanceModifier.defaultWeight())
        Text(heading(state), style = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.Medium, color = secondary))
        Text(
            if (state.phase == "transfer") state.transferStation ?: state.nextStopName else state.nextStopName,
            style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.Bold, color = GlanceTheme.colors.onSurface),
            maxLines = 2,
        )
        val time = if (state.phase == "transfer") state.transferDeparture ?: state.nextStopTime else state.nextStopTime
        val platform = if (state.phase == "transfer") state.transferPlatform else state.platform
        Text(
            timeString(time) + (platform?.let { "  Gl. $it" } ?: ""),
            style = TextStyle(
                fontSize = 13.sp, fontWeight = FontWeight.Medium, color = GlanceTheme.colors.onSurface,
                textDecoration = if (state.cancelled) TextDecoration.LineThrough else null,
            ),
        )
        state.warning?.let { Text(it, style = TextStyle(fontSize = 11.sp, color = ColorProvider(HeavyDelay)), maxLines = 2) }
        Spacer(GlanceModifier.defaultWeight())
        Text(
            "→ ${state.destinationName}  ${timeString(state.finalArrival)}",
            style = TextStyle(fontSize = 11.sp, color = secondary),
            maxLines = 1,
        )
    }
}

/** As on iOS: "Abfahrt" (with the day if not today), "Nächster Halt", "Umstieg", "Angekommen". */
private fun heading(state: WidgetState): String = when (state.phase) {
    "beforeDeparture" -> de.goldkunibert.betterbahn.ui.dayLabel(state.nextStopTime).let { if (it == "Heute") "Abfahrt" else "Abfahrt $it" }
    "transfer" -> "Umstieg"
    "arrived" -> "Angekommen"
    else -> "Nächster Halt"
}
