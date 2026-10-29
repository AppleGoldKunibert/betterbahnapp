package de.goldkunibert.betterbahn

import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import de.goldkunibert.betterbahn.kit.Kit
import de.goldkunibert.betterbahn.kit.Station
import kotlinx.coroutines.delay

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Kit.start(this)
        enableEdgeToEdge()
        setContent {
            val context = LocalContext.current
            val dark = isSystemInDarkTheme()
            // Wallpaper colours from Android 12 on.
            val colors = when {
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ->
                    if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
                dark -> darkColorScheme()
                else -> lightColorScheme()
            }
            MaterialTheme(colorScheme = colors) { StationSearchScreen() }
        }
    }
}

/** Prototype screen: the Kit's station search, to prove the Swift code runs on Android. */
@Composable
fun StationSearchScreen() {
    var query by remember { mutableStateOf("") }
    var stations by remember { mutableStateOf(emptyList<Station>()) }

    LaunchedEffect(query) {
        if (query.length < 2) {
            stations = emptyList()
            return@LaunchedEffect
        }
        delay(300)
        stations = Kit.searchStations(query)
    }

    Scaffold { padding ->
        Column(Modifier.fillMaxSize().padding(padding).padding(16.dp)) {
            OutlinedTextField(
                value = query,
                onValueChange = { query = it },
                label = { Text("Bahnhof suchen") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            LazyColumn {
                items(stations, key = { it.id }) { station ->
                    ListItem(
                        headlineContent = { Text(station.name) },
                        supportingContent = station.region?.let { { Text(it) } },
                    )
                }
            }
        }
    }
}
