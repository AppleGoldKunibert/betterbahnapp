@file:OptIn(ExperimentalMaterial3Api::class)

package de.goldkunibert.betterbahn.ui.departures

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import de.goldkunibert.betterbahn.AppModel
import de.goldkunibert.betterbahn.Route
import de.goldkunibert.betterbahn.kit.Kit
import de.goldkunibert.betterbahn.kit.Product
import de.goldkunibert.betterbahn.kit.TrainResult
import de.goldkunibert.betterbahn.ui.HeavyDelay
import de.goldkunibert.betterbahn.ui.TimeSelector
import de.goldkunibert.betterbahn.ui.productColor
import de.goldkunibert.betterbahn.ui.productIcon
import kotlinx.coroutines.launch

/** Finding a train by its number ("ICE 123", `TrainSearchOverlay`): the runs that day, a tap opens the train. */
@Composable
fun TrainSearchScreen(model: AppModel) {
    var text by remember { mutableStateOf("") }
    var day by remember { mutableStateOf<Long?>(null) }
    var submitted by remember { mutableIntStateOf(0) }
    var results by remember { mutableStateOf<List<TrainResult>?>(null) }
    var searching by remember { mutableStateOf(false) }
    var opening by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    val focus = remember { FocusRequester() }
    val scope = rememberCoroutineScope()

    LaunchedEffect(Unit) { focus.requestFocus() }
    LaunchedEffect(submitted, day) {
        if (submitted == 0 || text.isBlank()) return@LaunchedEffect
        searching = true
        error = null
        runCatching { Kit.searchTrains(text, day ?: System.currentTimeMillis()) }
            .onSuccess { found -> results = found.distinctBy { it.journeyId } }
            .onFailure { error = it.message; results = null }
        searching = false
    }

    fun open(result: TrainResult) {
        opening = result.journeyId
        error = null
        scope.launch {
            runCatching { Kit.trainRun(result) }
                .onSuccess { model.push(Route.TripLoaded(it)) }
                .onFailure { error = it.message ?: "Der Zug wurde nicht gefunden." }
            opening = null
        }
    }

    Column(Modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text("Zug suchen") },
            navigationIcon = { IconButton(onClick = { model.pop() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Zurück") } },
        )
        Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(
                value = text,
                onValueChange = { text = it },
                modifier = Modifier.fillMaxWidth().focusRequester(focus),
                label = { Text("Zugnummer") },
                placeholder = { Text("z. B. ICE 123") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                keyboardActions = KeyboardActions(onSearch = { submitted++ }),
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Tag", Modifier.weight(1f))
                TimeSelector(day, onChange = { day = it })
            }
            error?.let { Text(it, color = HeavyDelay, style = MaterialTheme.typography.bodySmall) }
        }
        when {
            searching -> CircularProgressIndicator(Modifier.padding(24.dp).align(Alignment.CenterHorizontally))
            results?.isEmpty() == true -> Text("Kein Zug mit dieser Nummer gefunden.", Modifier.padding(24.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
            else -> LazyColumn {
                items(results.orEmpty(), key = { it.journeyId }) { result ->
                    val product = Product.of(result.product)
                    ListItem(
                        modifier = Modifier.clickable(enabled = opening == null) { open(result) },
                        leadingContent = { Icon(productIcon(product), null, tint = productColor(product)) },
                        headlineContent = { Text(listOfNotNull(result.name, result.lineName).joinToString(" · ")) },
                        supportingContent = { Text("${result.origin} → ${result.destination}") },
                        trailingContent = { if (opening == result.journeyId) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp) },
                    )
                    HorizontalDivider()
                }
            }
        }
    }
}
