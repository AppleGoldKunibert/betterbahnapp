package de.goldkunibert.betterbahn

import android.Manifest
import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.filled.DepartureBoard
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.Search
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.TextButton
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.lifecycle.lifecycleScope
import de.goldkunibert.betterbahn.data.Notifier
import de.goldkunibert.betterbahn.data.SavedRefresh
import de.goldkunibert.betterbahn.data.Store
import de.goldkunibert.betterbahn.widget.WidgetStations
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Modifier
import de.goldkunibert.betterbahn.kit.Kit
import de.goldkunibert.betterbahn.ui.BetterBahnTheme
import de.goldkunibert.betterbahn.ui.connections.ConnectionsScreen
import de.goldkunibert.betterbahn.ui.connections.JourneyDetailScreen
import de.goldkunibert.betterbahn.ui.connections.ResultsScreen
import de.goldkunibert.betterbahn.ui.departures.DeparturesScreen
import de.goldkunibert.betterbahn.ui.departures.TrainSearchScreen
import de.goldkunibert.betterbahn.ui.departures.TripScreen
import de.goldkunibert.betterbahn.ui.settings.SettingsScreen
import de.goldkunibert.betterbahn.ui.trips.PastTripsScreen
import de.goldkunibert.betterbahn.ui.trips.TripsScreen

class MainActivity : ComponentActivity() {
    companion object {
        /** Opens this saved journey (from a notification). */
        const val EXTRA_SAVED_ID = "savedId"
    }

    private val model: AppModel by viewModels()
    private val askNotifications = registerForActivityResult(ActivityResultContracts.RequestPermission()) {}

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Kit.start(this)
        Notifier.createChannel(this)
        if (Store.get(this).savedJourneys.value.isNotEmpty() || WidgetStations.hasAny(this)) SavedRefresh.schedule(this)
        enableEdgeToEdge()
        if (savedInstanceState == null) handleShare(intent)
        setContent {
            BetterBahnTheme { App(model) }
            if (model.wantsNotificationPermission) {
                LaunchedEffect(Unit) {
                    model.wantsNotificationPermission = false
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) askNotifications.launch(Manifest.permission.POST_NOTIFICATIONS)
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleShare(intent)
    }

    /** A connection shared from DB Navigator ("Teilen" → BetterBahn), or a saved journey from its notification. */
    private fun handleShare(intent: Intent?) {
        intent?.getStringExtra(EXTRA_SAVED_ID)?.let { id ->
            // Saved journeys are described shortly after start; wait for it.
            lifecycleScope.launch {
                repeat(50) {
                    if (model.savedDisplays.containsKey(id)) return@launch model.openSaved(id)
                    delay(100)
                }
            }
            return
        }
        if (intent?.action != Intent.ACTION_SEND) return
        val text = listOfNotNull(intent.getStringExtra(Intent.EXTRA_SUBJECT), intent.getStringExtra(Intent.EXTRA_TEXT)).joinToString("\n")
        if (text.isNotBlank()) model.importShared(text)
    }
}

/** Four tabs as on iOS, each with its own stack of screens; Back goes up the open tab's stack. */
@Composable
fun App(model: AppModel) {
    val states = rememberSaveableStateHolder()
    val stack = model.stack(model.tab)
    // Back goes up the open tab's stack, then to the first tab (Android's usual way), then leaves the app.
    BackHandler(enabled = stack.isNotEmpty() || model.tab != Tab.Connections) {
        val popped = model.pop()
        if (popped == null) model.tab = Tab.Connections else states.removeState(popped.key)
    }

    if (model.importing) {
        AlertDialog(
            onDismissRequest = {},
            confirmButton = {},
            title = { Text("Verbindung wird gesucht …") },
            text = { LinearProgressIndicator(Modifier.fillMaxWidth()) },
        )
    }
    model.importError?.let { message ->
        AlertDialog(
            onDismissRequest = { model.importError = null },
            confirmButton = { TextButton(onClick = { model.importError = null }) { Text("OK") } },
            title = { Text("Nicht gefunden") },
            text = { Text(message) },
        )
    }

    Scaffold(bottomBar = {
        NavigationBar {
            for (tab in Tab.entries) {
                NavigationBarItem(
                    selected = model.tab == tab,
                    onClick = { model.selectTab(tab) },
                    icon = {
                        Icon(
                            when (tab) {
                                Tab.Connections -> Icons.Filled.Search
                                Tab.Departures -> Icons.Filled.DepartureBoard
                                Tab.Trips -> Icons.Filled.Bookmark
                                Tab.Settings -> Icons.Filled.MoreHoriz
                            },
                            null,
                        )
                    },
                    label = { Text(tab.title) },
                )
            }
        }
    }) { padding ->
        // The bars' insets are used here; each screen's top bar must not add the status bar again.
        Box(Modifier.fillMaxSize().padding(padding).consumeWindowInsets(padding)) {
            val route = stack.lastOrNull()
            // Each screen keeps its scroll position and inputs while another one is on top.
            states.SaveableStateProvider(route?.key ?: model.tab.name) {
                when (route) {
                    null -> when (model.tab) {
                        Tab.Connections -> ConnectionsScreen(model)
                        Tab.Departures -> DeparturesScreen(model)
                        Tab.Trips -> TripsScreen(model)
                        Tab.Settings -> SettingsScreen(model)
                    }
                    is Route.Results -> ResultsScreen(model, route.state)
                    is Route.Detail -> JourneyDetailScreen(model, route)
                    is Route.TripFromBoard -> {
                        val entry = route.entry.entry
                        val departures = entry.kind == "departures"
                        TripScreen(model, boardingAt = entry.station.takeIf { departures }, exitAt = entry.station.takeIf { !departures }) {
                            Kit.trip(entry.tripId, entry.source)
                        }
                    }
                    is Route.TripFromLeg -> {
                        val leg = route.journey.journey.legs[route.legIndex]
                        TripScreen(model, boardingAt = leg.origin, exitAt = leg.destination) { Kit.tripForLeg(route.journey.rawLeg(route.legIndex)) }
                    }
                    is Route.TripLoaded -> TripScreen(model, boardingAt = null, exitAt = null, loaded = route.run.trip) {
                        Kit.trip(route.run.entry.entry.tripId, route.run.entry.entry.source)
                    }
                    is Route.TrainSearch -> TrainSearchScreen(model)
                    is Route.PastTrips -> PastTripsScreen(model)
                }
            }
        }
    }
}
