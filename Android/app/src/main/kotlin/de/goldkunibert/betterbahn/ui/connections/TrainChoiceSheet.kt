@file:OptIn(ExperimentalMaterial3Api::class)

package de.goldkunibert.betterbahn.ui.connections

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import de.goldkunibert.betterbahn.kit.Kit
import de.goldkunibert.betterbahn.kit.Station
import de.goldkunibert.betterbahn.kit.TrainCandidate
import de.goldkunibert.betterbahn.ui.DesignCard
import de.goldkunibert.betterbahn.ui.LineBadge
import de.goldkunibert.betterbahn.ui.timeString
import kotlinx.coroutines.delay

/**
 * "Bestimmter Zug" (`TrainNumberSheet`, #225): what's typed ("ICE 91", "RE 3") is looked for on the boards of the
 * route's stations; a train calling on the route can be picked, boarding where the route meets it and, where it goes
 * on to the destination, getting off there. The route itself is planned by the results page.
 */
@Composable
fun TrainChoiceSheet(stations: List<Station>, target: Station, date: Long, onPick: (TrainCandidate) -> Unit, onDismiss: () -> Unit) {
    var text by remember { mutableStateOf("") }
    var candidates by remember { mutableStateOf<List<TrainCandidate>>(emptyList()) }
    var searching by remember { mutableStateOf(false) }
    val focus = remember { FocusRequester() }
    val trimmed = text.trim()

    // Searches while typing, a moment after the last key. The boards load once, with the first search.
    LaunchedEffect(trimmed) {
        if (trimmed.isEmpty()) {
            candidates = emptyList()
            return@LaunchedEffect
        }
        delay(350)
        searching = true
        candidates = runCatching { Kit.trainCandidates(trimmed, stations, target, date) }.getOrDefault(emptyList())
        searching = false
    }
    LaunchedEffect(Unit) { focus.requestFocus() }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(
            Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 24.dp).navigationBarsPadding(),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Bestimmter Zug", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
            OutlinedTextField(
                value = text,
                onValueChange = { text = it },
                modifier = Modifier.fillMaxWidth().focusRequester(focus),
                placeholder = { Text("Tippe Zugname, Linie oder Zugnummer…") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters),
            )
            val usable = candidates.filter { it.requirement != null }
            when {
                searching && usable.isEmpty() -> Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                    Text("Suche Züge …", Modifier.padding(start = 10.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                trimmed.isNotEmpty() && !searching && usable.isEmpty() ->
                    Text("Kein passender Zug auf deiner Strecke.", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (usable.isNotEmpty()) {
                Text("Züge auf deiner Strecke", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                DesignCard {
                    usable.forEachIndexed { index, candidate ->
                        if (index > 0) HorizontalDivider(Modifier.padding(start = 16.dp))
                        CandidateRow(candidate, target) { onPick(candidate) }
                    }
                }
            }
        }
    }
}

@Composable
private fun CandidateRow(candidate: TrainCandidate, target: Station, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                LineBadge(candidate.line, small = true)
                candidate.direction?.let { Text("→ $it", maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyMedium) }
            }
            candidate.boarding?.let { boarding ->
                val time = boarding.departure?.planned?.let(::timeString).orEmpty()
                Text("ab ${boarding.station.shownName} $time", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Text(
                candidate.exit?.let { exit -> "fährt bis ${exit.station.shownName}" + (exit.arrival?.planned?.let { " · an ${timeString(it)}" } ?: "") }
                    ?: "fährt nicht bis ${target.shownName}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}
