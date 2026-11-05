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
import androidx.glance.appwidget.GlanceAppWidgetManager
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
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextDecoration
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import de.goldkunibert.betterbahn.MainActivity
import de.goldkunibert.betterbahn.kit.BoardWidgetRow
import de.goldkunibert.betterbahn.kit.Kit
import de.goldkunibert.betterbahn.kit.Product
import de.goldkunibert.betterbahn.kit.Station
import de.goldkunibert.betterbahn.ui.timeString

/**
 * "Abfahrten" (`StationBoardWidget` on iOS): the next departures from a station picked when placing the widget,
 * from Transitous. Reloads with the background refresh (every 15 minutes) and every 30 minutes.
 */
class BoardWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val widgetId = GlanceAppWidgetManager(context).getAppWidgetId(id)
        val choice = WidgetStations.board(context, widgetId)
        var rows: List<BoardWidgetRow>? = null
        if (choice != null) {
            Kit.start(context)
            rows = runCatching { Kit.boardWidgetRows(choice.station, choice.products) }.getOrNull()
        }
        val loadedAt = System.currentTimeMillis()
        provideContent {
            GlanceTheme { Content(choice?.station, rows, loadedAt) }
        }
    }

    companion object {
        suspend fun update(context: Context) = BoardWidget().updateAll(context)
    }
}

class BoardWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = BoardWidget()

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        super.onDeleted(context, appWidgetIds)
        appWidgetIds.forEach { WidgetStations.remove(context, it) }
    }
}

private val Punctual = Color(0xFF219E59)
private val SlightDelay = Color(0xFFF28C0D)
private val HeavyDelay = Color(0xFFE02633)

@Composable
private fun Content(station: Station?, rows: List<BoardWidgetRow>?, loadedAt: Long) {
    val secondary = GlanceTheme.colors.onSurfaceVariant
    val primary = GlanceTheme.colors.onSurface
    Column(
        GlanceModifier.fillMaxSize().background(GlanceTheme.colors.widgetBackground).cornerRadius(16.dp).padding(12.dp)
            .clickable(actionStartActivity<MainActivity>()),
    ) {
        if (station == null) {
            Text("Kein Bahnhof gewählt", style = TextStyle(fontWeight = FontWeight.Bold, color = primary))
            Text("Halte das Widget gedrückt und wähle einen Bahnhof.", style = TextStyle(fontSize = 12.sp, color = secondary))
            return@Column
        }
        Row(GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(station.shownName, GlanceModifier.defaultWeight(), style = TextStyle(fontWeight = FontWeight.Bold, color = primary), maxLines = 1)
            Text(timeString(loadedAt), style = TextStyle(fontSize = 10.sp, color = secondary))
        }
        Spacer(GlanceModifier.height(6.dp))
        when {
            rows == null -> Text("Gerade keine Daten", style = TextStyle(fontSize = 12.sp, color = secondary))
            rows.isEmpty() -> Text("Keine Abfahrten in der nächsten Stunde", style = TextStyle(fontSize = 12.sp, color = secondary))
            else -> rows.forEach { row -> BoardRow(row) }
        }
    }
}

@Composable
private fun BoardRow(row: BoardWidgetRow) {
    val primary = GlanceTheme.colors.onSurface
    val secondary = GlanceTheme.colors.onSurfaceVariant
    Row(GlanceModifier.fillMaxWidth().padding(vertical = 2.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(
            timeString(row.departure.planned),
            style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Bold, color = primary,
                textDecoration = if (row.cancelled) TextDecoration.LineThrough else null),
        )
        val delay = row.departure.delayMinutes
        Text(
            when {
                row.cancelled -> " ✕"
                delay != null && delay > 0 -> " +$delay"
                else -> ""
            },
            style = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.Bold, color = ColorProvider(
                when {
                    row.cancelled || (delay ?: 0) > 10 -> HeavyDelay
                    (delay ?: 0) > 5 -> SlightDelay
                    else -> Punctual
                },
            )),
        )
        Spacer(GlanceModifier.width(6.dp))
        Text(row.lineName, style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.Bold, color = ColorProvider(productColor(row.product))), maxLines = 1)
        Spacer(GlanceModifier.width(6.dp))
        Text(row.destination, GlanceModifier.defaultWeight(), style = TextStyle(fontSize = 12.sp, color = primary), maxLines = 1)
        row.platform?.let { Text("Gl. $it", style = TextStyle(fontSize = 11.sp, color = secondary)) }
    }
}

/** The product colours of `ui/Theme.kt` (light variant; the widget background is light or dark). */
private fun productColor(id: String): Color = when (Product.of(id)) {
    Product.HighSpeed, Product.LongDistance, Product.NightTrain, Product.Interregio -> Color(0xFF6B6B6B)
    Product.RegionalExpress, Product.Regional -> Color(0xFFDB1730)
    Product.Suburban -> Color(0xFF1A994D)
    Product.Bus, Product.Coach -> Color(0xFF8547BD)
    Product.Subway -> Color(0xFF1F61CC)
    Product.Tram -> Color(0xFFCC731A)
    Product.Ferry -> Color(0xFF1A8CCC)
    Product.Other -> Color.Gray
}
