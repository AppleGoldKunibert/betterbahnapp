@file:OptIn(ExperimentalMaterial3Api::class)

package de.goldkunibert.betterbahn.ui.settings

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
    Column(Modifier.fillMaxSize()) {
        TopAppBar(title = { Text("Mehr") })
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
