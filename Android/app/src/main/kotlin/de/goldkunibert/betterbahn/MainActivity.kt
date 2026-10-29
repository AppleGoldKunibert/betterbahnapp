package de.goldkunibert.betterbahn

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.filled.DepartureBoard
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Modifier
import androidx.lifecycle.viewmodel.compose.viewModel
import de.goldkunibert.betterbahn.kit.Kit
import de.goldkunibert.betterbahn.ui.BetterBahnTheme
import de.goldkunibert.betterbahn.ui.connections.ConnectionsScreen
import de.goldkunibert.betterbahn.ui.connections.JourneyDetailScreen
import de.goldkunibert.betterbahn.ui.connections.ResultsScreen
import de.goldkunibert.betterbahn.ui.departures.DeparturesScreen
import de.goldkunibert.betterbahn.ui.departures.TripScreen
import de.goldkunibert.betterbahn.ui.settings.SettingsScreen
import de.goldkunibert.betterbahn.ui.trips.PastTripsScreen
import de.goldkunibert.betterbahn.ui.trips.TripsScreen

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Kit.start(this)
        enableEdgeToEdge()
        setContent {
            BetterBahnTheme { App(viewModel()) }
        }
    }
}

/** Four tabs as on iOS, each with its own stack of screens; Back goes up the open tab's stack. */
@Composable
fun App(model: AppModel) {
    val states = rememberSaveableStateHolder()
    val stack = model.stack(model.tab)
    BackHandler(enabled = stack.isNotEmpty()) { model.pop() }

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
        Box(Modifier.fillMaxSize().padding(padding)) {
            val route = stack.lastOrNull()
            // Each screen keeps its scroll position and inputs while another one is on top.
            states.SaveableStateProvider("${model.tab}/${stack.size}") {
                when (route) {
                    null -> when (model.tab) {
                        Tab.Connections -> ConnectionsScreen(model)
                        Tab.Departures -> DeparturesScreen(model)
                        Tab.Trips -> TripsScreen(model)
                        Tab.Settings -> SettingsScreen(model)
                    }
                    is Route.Results -> ResultsScreen(model, route.state)
                    is Route.Detail -> JourneyDetailScreen(model, route)
                    is Route.TripFromBoard -> TripScreen(model, listOf(route.entry.entry.station)) {
                        Kit.trip(route.entry.entry.tripId, route.entry.entry.source)
                    }
                    is Route.TripFromLeg -> {
                        val leg = route.journey.journey.legs[route.legIndex]
                        TripScreen(model, listOf(leg.origin, leg.destination)) { Kit.tripForLeg(route.journey.rawLeg(route.legIndex)) }
                    }
                    Route.PastTrips -> PastTripsScreen(model)
                }
            }
        }
    }
}
