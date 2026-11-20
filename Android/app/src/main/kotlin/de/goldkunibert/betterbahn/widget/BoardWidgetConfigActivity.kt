package de.goldkunibert.betterbahn.widget

import android.appwidget.AppWidgetManager
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.glance.appwidget.GlanceAppWidgetManager
import androidx.lifecycle.lifecycleScope
import de.goldkunibert.betterbahn.data.SavedRefresh
import de.goldkunibert.betterbahn.data.Store
import de.goldkunibert.betterbahn.kit.Product
import de.goldkunibert.betterbahn.kit.Station
import de.goldkunibert.betterbahn.ui.BetterBahnTheme
import kotlinx.coroutines.launch

/** Picking the departures widget's station from the favourites and recent stations (the widget's settings on iOS). */
class BoardWidgetConfigActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val widgetId = intent?.extras?.getInt(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
            ?: AppWidgetManager.INVALID_APPWIDGET_ID
        // Backing out leaves no widget behind.
        setResult(RESULT_CANCELED, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId))
        if (widgetId == AppWidgetManager.INVALID_APPWIDGET_ID) return finish()
        val store = Store.get(this)
        val stations = (store.favorites.value + store.recentStations.value)
            .fold(emptyList<Station>()) { list, s -> if (list.any { it.isSamePlace(s) }) list else list + s }
        val previous = WidgetStations.board(this, widgetId)

        enableEdgeToEdge()
        setContent {
            BetterBahnTheme {
                var onlyTrains by remember { mutableStateOf(previous?.products?.let { it == Product.trains } ?: true) }
                Scaffold { padding ->
                    Column(Modifier.fillMaxSize().padding(padding)) {
                        Text("Abfahrten von", Modifier.padding(16.dp), style = MaterialTheme.typography.titleLarge)
                        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text("Nur Züge", Modifier.weight(1f))
                            Switch(checked = onlyTrains, onCheckedChange = { onlyTrains = it })
                        }
                        if (stations.isEmpty()) {
                            Text(
                                "Merke dir zuerst einen Bahnhof in der App: Abfahrten → Bahnhof suchen → Stern.",
                                Modifier.padding(16.dp),
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        LazyColumn {
                            items(stations, key = { it.source + it.id }) { station ->
                                val favorite = store.isFavorite(station)
                                ListItem(
                                    modifier = Modifier.clickable { pick(widgetId, station, onlyTrains) },
                                    leadingContent = { Icon(if (favorite) Icons.Filled.Star else Icons.Filled.History, null) },
                                    headlineContent = { Text(station.shownName) },
                                )
                                HorizontalDivider()
                            }
                        }
                    }
                }
            }
        }
    }

    private fun pick(widgetId: Int, station: Station, onlyTrains: Boolean) {
        WidgetStations.setBoard(this, widgetId, BoardWidgetChoice(station, if (onlyTrains) Product.trains else null))
        SavedRefresh.schedule(this)
        lifecycleScope.launch {
            runCatching {
                val glanceId = GlanceAppWidgetManager(this@BoardWidgetConfigActivity).getGlanceIdBy(widgetId)
                BoardWidget().update(this@BoardWidgetConfigActivity, glanceId)
            }
            setResult(RESULT_OK, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId))
            finish()
        }
    }
}
