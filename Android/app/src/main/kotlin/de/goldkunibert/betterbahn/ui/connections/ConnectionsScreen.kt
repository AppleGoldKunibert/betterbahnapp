@file:OptIn(ExperimentalMaterial3Api::class)

package de.goldkunibert.betterbahn.ui.connections

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.SwapVert
import androidx.compose.material.icons.filled.TripOrigin
import androidx.compose.material.icons.filled.Place
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import de.goldkunibert.betterbahn.AppModel
import de.goldkunibert.betterbahn.Route
import de.goldkunibert.betterbahn.data.ConnectionSearch
import de.goldkunibert.betterbahn.ui.ProductFilterSheet
import de.goldkunibert.betterbahn.ui.StationPicker
import de.goldkunibert.betterbahn.ui.TimeSelector
import de.goldkunibert.betterbahn.ui.productSummary

private enum class Field { From, To }

/** The connection search (`ConnectionsView`): start, destination, time, options, recent searches. */
@Composable
fun ConnectionsScreen(model: AppModel) {
    val form = model.form
    var picking by remember { mutableStateOf<Field?>(null) }
    var filtering by remember { mutableStateOf(false) }
    val recentSearches by model.store.recentSearches.collectAsState()

    fun search(search: ConnectionSearch) {
        model.store.rememberSearch(search.from, search.to)
        model.push(Route.Results(search))
    }

    Column(Modifier.fillMaxSize()) {
        TopAppBar(title = { Text("Verbindungen") })
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Card {
                Box {
                    Column {
                        StationField("Start", form.from?.shownName, "Von wo?", Icons.Filled.TripOrigin) { picking = Field.From }
                        HorizontalDivider(Modifier.padding(start = 56.dp, end = 56.dp))
                        StationField("Ziel", form.to?.shownName, "Wohin?", Icons.Filled.Place) { picking = Field.To }
                    }
                    IconButton(
                        onClick = { model.form = form.copy(from = form.to, to = form.from) },
                        modifier = Modifier.align(Alignment.CenterEnd).padding(end = 4.dp),
                    ) { Icon(Icons.Filled.SwapVert, "Start und Ziel tauschen") }
                }
            }
            Card {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                        listOf("Abfahrt" to false, "Ankunft" to true).forEachIndexed { index, (label, arrival) ->
                            SegmentedButton(
                                selected = form.isArrival == arrival,
                                onClick = { model.form = form.copy(isArrival = arrival) },
                                shape = SegmentedButtonDefaults.itemShape(index, 2),
                            ) { Text(label) }
                        }
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Zeit", Modifier.weight(1f))
                        TimeSelector(form.date, onChange = { model.form = form.copy(date = it) })
                    }
                    Text("Max. Umstiege")
                    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                        val options = listOf("Beliebig" to null, "Direkt" to 0, "≤ 1" to 1, "≤ 2" to 2)
                        options.forEachIndexed { index, (label, value) ->
                            SegmentedButton(
                                selected = form.maxTransfers == value,
                                onClick = { model.form = form.copy(maxTransfers = value) },
                                shape = SegmentedButtonDefaults.itemShape(index, options.size),
                            ) { Text(label) }
                        }
                    }
                    Row(Modifier.fillMaxWidth().clickable { filtering = true }, verticalAlignment = Alignment.CenterVertically) {
                        Text("Verkehrsmittel", Modifier.weight(1f))
                        Text(productSummary(form.products), color = MaterialTheme.colorScheme.primary, maxLines = 1)
                    }
                }
            }
            Button(
                onClick = { form.search()?.let(::search) },
                enabled = form.from != null && form.to != null && form.products.isNotEmpty(),
                modifier = Modifier.fillMaxWidth().height(52.dp),
            ) { Text("Verbindungen suchen", fontWeight = FontWeight.SemiBold) }

            if (recentSearches.isNotEmpty()) {
                Text("Zuletzt gesucht", style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(top = 8.dp))
                Card {
                    recentSearches.forEachIndexed { index, recent ->
                        if (index > 0) HorizontalDivider()
                        ListItem(
                            modifier = Modifier.clickable {
                                model.form = form.copy(from = recent.from, to = recent.to)
                                model.form.search()?.let(::search)
                            },
                            colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surfaceContainerHighest.copy(alpha = 0f)),
                            headlineContent = {
                                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                    Text(recent.from.shownName, Modifier.weight(1f, fill = false), maxLines = 1)
                                    Icon(Icons.AutoMirrored.Filled.ArrowForward, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                                    Text(recent.to.shownName, Modifier.weight(1f, fill = false), maxLines = 1)
                                }
                            },
                            trailingContent = {
                                IconButton(onClick = { model.store.removeSearch(recent) }) { Icon(Icons.Filled.Close, "Entfernen") }
                            },
                        )
                    }
                }
            }
            Spacer(Modifier.height(24.dp))
        }
    }

    picking?.let { field ->
        StationPicker(
            store = model.store,
            placeholder = if (field == Field.From) "Von wo?" else "Wohin?",
            onPick = { station ->
                model.form = if (field == Field.From) form.copy(from = station) else form.copy(to = station)
                picking = null
            },
            onDismiss = { picking = null },
        )
    }
    if (filtering) {
        ProductFilterSheet(form.products, onChange = { model.form = model.form.copy(products = it) }, onDismiss = { filtering = false })
    }
}

@Composable
private fun StationField(label: String, value: String?, placeholder: String, icon: androidx.compose.ui.graphics.vector.ImageVector, onClick: () -> Unit) {
    ListItem(
        modifier = Modifier.clickable(onClick = onClick).padding(end = 48.dp),
        colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surfaceContainerHighest.copy(alpha = 0f)),
        leadingContent = { Icon(icon, null, tint = MaterialTheme.colorScheme.primary) },
        overlineContent = { Text(label) },
        headlineContent = {
            Text(value ?: placeholder, color = if (value == null) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface, maxLines = 1)
        },
    )
}
