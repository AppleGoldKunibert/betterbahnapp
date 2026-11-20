@file:OptIn(ExperimentalMaterial3Api::class)

package de.goldkunibert.betterbahn.ui.settings

import de.goldkunibert.betterbahn.data.BikeOption
import de.goldkunibert.betterbahn.data.AppDesign
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.Alignment
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.Switch
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import de.goldkunibert.betterbahn.kit.TicketType
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import de.goldkunibert.betterbahn.AppModel

/** "Mehr": what the app is, its version, clearing the history. */
@Composable
fun SettingsScreen(model: AppModel) {
    val context = LocalContext.current
    val version = context.packageManager.getPackageInfo(context.packageName, 0).versionName
    val ticket by model.store.ticketType.collectAsState()
    val settings = model.store.settings
    val design by settings.design.state.collectAsState()
    val bike by settings.bikeOption.state.collectAsState()
    val ticketFilterByDefault by settings.ticketFilterByDefault.state.collectAsState()
    val expert by settings.expertMode.state.collectAsState()
    val trainChoice by settings.expertTrainChoice.state.collectAsState()
    Column(Modifier.fillMaxSize()) {
        TopAppBar(title = { Text("Mehr") }, colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent))
        Column(Modifier.verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Card {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("BetterBahn für Android", style = MaterialTheme.typography.titleMedium)
                    Text("Vorabversion $version. Noch nicht alles aus der iPhone-App ist schon da.", style = MaterialTheme.typography.bodyMedium)
                    Text("Verbindungen und Abfahrten kommen von Transitous, mit Daten der Verkehrsunternehmen.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            Card {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Dein Ticket", style = MaterialTheme.typography.titleMedium)
                    Text("Für „Nur …“ in der Suche und bei den Abfahrten.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                        TicketType.entries.forEachIndexed { index, type ->
                            SegmentedButton(
                                selected = ticket == type,
                                onClick = { model.store.setTicketType(type) },
                                shape = SegmentedButtonDefaults.itemShape(index, TicketType.entries.size),
                            ) { Text(type.displayName) }
                        }
                    }
                    SwitchRow("Nur passende Züge zeigen", "Die Suche startet mit „${ticket.filterTitle}“.", ticketFilterByDefault) {
                        settings.ticketFilterByDefault.set(it)
                    }
                }
            }
            Card {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Design", style = MaterialTheme.typography.titleMedium)
                    Choice(AppDesign.entries, design, { it.displayName }) { settings.design.set(it) }
                    Text(
                        if (design == AppDesign.Fahrkarte) "Die Suche als Fahrkarte, flache Karten auf warmem Grund." else "Ruhige Karten, selten geänderte Optionen eingeklappt.",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            Card {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Fahrrad", style = MaterialTheme.typography.titleMedium)
                    Choice(BikeOption.entries, bike, { it.displayName }) { settings.bikeOption.set(it) }
                    Text(
                        if (bike == BikeOption.Hidden) "Mit Klapprad oder Fahrrad zeigt die Suche, wo es mitkommt und ob du eine Reservierung oder Fahrradkarte brauchst."
                        else "In der Suche schaltest du ein, ob es diesmal mitkommt.",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            Card {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    SwitchRow("Expertenmodus", null, expert) { settings.expertMode.set(it) }
                    if (expert) {
                        SwitchRow("Bestimmten Zug wählen", "Einen bestimmten Zug in die Reise übernehmen.", trainChoice) {
                            settings.expertTrainChoice.set(it)
                        }
                    }
                }
            }
            Card {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Datenschutz", style = MaterialTheme.typography.titleMedium)
                    Text("Dein Standort verlässt dein Handy nicht. Favoriten, Suchverlauf und Reisen bleiben auf dem Gerät.", style = MaterialTheme.typography.bodyMedium)
                }
            }
            OutlinedButton(onClick = { model.store.clearHistory() }) { Text("Suchverlauf löschen") }
        }
    }
}

/** A title, an optional note and a switch. */
@Composable
fun SwitchRow(title: String, subtitle: String?, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title)
            subtitle?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
        Switch(checked = checked, onCheckedChange = onChange)
    }
}

/** One of a few options as segmented buttons. */
@Composable
fun <T> Choice(options: List<T>, selected: T, label: (T) -> String, onSelect: (T) -> Unit) {
    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
        options.forEachIndexed { index, option ->
            SegmentedButton(
                selected = option == selected,
                onClick = { onSelect(option) },
                shape = SegmentedButtonDefaults.itemShape(index, options.size),
            ) { Text(label(option), maxLines = 1) }
        }
    }
}
