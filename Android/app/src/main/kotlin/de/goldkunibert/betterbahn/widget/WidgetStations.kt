package de.goldkunibert.betterbahn.widget

import android.content.Context
import de.goldkunibert.betterbahn.kit.KitJson
import de.goldkunibert.betterbahn.kit.Product
import de.goldkunibert.betterbahn.kit.Station
import kotlinx.serialization.Serializable

/** What a departures widget shows (`StationBoardWidgetIntent` on iOS). */
@Serializable
data class BoardWidgetChoice(val station: Station, val products: Set<Product>? = null)

/** Each departures widget's station, by its widget ID. */
object WidgetStations {
    private fun prefs(context: Context) = context.getSharedPreferences("widgets", Context.MODE_PRIVATE)

    fun board(context: Context, widgetId: Int): BoardWidgetChoice? =
        prefs(context).getString("board.$widgetId", null)?.let {
            runCatching { KitJson.json.decodeFromString(BoardWidgetChoice.serializer(), it) }.getOrNull()
        }

    fun setBoard(context: Context, widgetId: Int, choice: BoardWidgetChoice) {
        prefs(context).edit().putString("board.$widgetId", KitJson.json.encodeToString(BoardWidgetChoice.serializer(), choice)).apply()
    }

    fun remove(context: Context, widgetId: Int) {
        prefs(context).edit().remove("board.$widgetId").apply()
    }

    fun hasAny(context: Context): Boolean = prefs(context).all.keys.any { it.startsWith("board.") }
}
