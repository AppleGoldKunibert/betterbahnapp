package de.goldkunibert.betterbahn.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.StarBorder
import androidx.compose.material.icons.filled.Train
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import de.goldkunibert.betterbahn.data.Store
import de.goldkunibert.betterbahn.kit.Kit
import de.goldkunibert.betterbahn.kit.Station
import kotlinx.coroutines.delay
import java.text.Normalizer

private val Gold = Color(0xFFF2B705)

/**
 * Full-screen station search (`StationPicker` on iOS): favourites and recent stations while the field is empty,
 * the Kit's search after a short pause while typing. Enter picks the first result.
 */
@Composable
fun StationPicker(store: Store, placeholder: String, onPick: (Station) -> Unit, onDismiss: () -> Unit) {
    var query by remember { mutableStateOf("") }
    var results by remember { mutableStateOf<List<Station>?>(null) }
    var searching by remember { mutableStateOf(false) }
    var pickFirst by remember { mutableStateOf(false) }
    val favorites by store.favorites.collectAsState()
    val recents by store.recentStations.collectAsState()
    val focus = remember { FocusRequester() }

    fun pick(station: Station) {
        store.rememberStation(station)
        onPick(station)
    }

    LaunchedEffect(query) {
        if (query.trim().length < 2) {
            results = null
            searching = false
            return@LaunchedEffect
        }
        searching = true
        delay(250)
        val found = runCatching { Kit.searchStations(query) }.getOrDefault(emptyList())
        results = found
        searching = false
        if (pickFirst) found.firstOrNull()?.let(::pick)
    }
    LaunchedEffect(Unit) { focus.requestFocus() }

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Scaffold(topBar = {
            TextField(
                value = query,
                onValueChange = { query = it; pickFirst = false },
                modifier = Modifier.fillMaxWidth().focusRequester(focus),
                placeholder = { Text(placeholder) },
                singleLine = true,
                leadingIcon = { IconButton(onClick = onDismiss) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Zurück") } },
                trailingIcon = {
                    if (query.isNotEmpty()) IconButton(onClick = { query = "" }) { Icon(Icons.Filled.Clear, "Leeren") }
                },
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                keyboardActions = KeyboardActions(onSearch = {
                    val first = results?.firstOrNull()
                    if (first != null && !searching) pick(first) else pickFirst = true
                }),
                colors = TextFieldDefaults.colors(
                    focusedContainerColor = MaterialTheme.colorScheme.surface,
                    unfocusedContainerColor = MaterialTheme.colorScheme.surface,
                ),
            )
        }) { padding ->
            Column(Modifier.fillMaxSize().padding(padding).imePadding()) {
                HorizontalDivider()
                val typed = results != null || searching
                val shown = if (typed) results.orEmpty() else
                    (favorites + recents).fold(emptyList<Station>()) { list, s -> if (list.any { it.isSamePlace(s) }) list else list + s }
                if (searching && results == null) {
                    CircularProgressIndicator(Modifier.padding(24.dp))
                }
                if (typed && !searching && shown.isEmpty()) {
                    Text("Kein Bahnhof gefunden", Modifier.padding(24.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                LazyColumn {
                    items(shown, key = { it.source + it.id }) { station ->
                        val favorite = favorites.any { it.isSamePlace(station) }
                        val needsRegion = station.region != null && shown.count { sameName(it, station) } > 1
                        ListItem(
                            modifier = Modifier.clickable { pick(station) },
                            leadingContent = {
                                Icon(
                                    when {
                                        favorite -> Icons.Filled.Star
                                        typed -> Icons.Filled.Train
                                        else -> Icons.Filled.History
                                    },
                                    null,
                                    tint = if (favorite) Gold else MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            },
                            headlineContent = { Text(highlighted(station.shownName, if (typed) query else "")) },
                            supportingContent = if (needsRegion) ({ Text(station.region) }) else null,
                            trailingContent = {
                                IconButton(onClick = { store.toggleFavorite(station) }) {
                                    Icon(
                                        if (favorite) Icons.Filled.Star else Icons.Filled.StarBorder,
                                        if (favorite) "Aus Favoriten entfernen" else "Zu Favoriten",
                                        tint = if (favorite) Gold else MaterialTheme.colorScheme.onSurfaceVariant,
                                    )
                                }
                            },
                        )
                    }
                }
                if (!typed) {
                    Text(
                        "Tipp: „b“ vor oder hinter dem Namen sucht Bushaltestellen, „t“ Trams.",
                        Modifier.padding(16.dp),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

/** Same name apart from "Bahnhof"/"Hbf"/"Bhf", so the region tells them apart (as on iOS). */
private fun sameName(a: Station, b: Station): Boolean {
    fun core(s: Station) = s.shownName.lowercase().replace(Regex("\\b(bahnhof|hbf|bhf)\\b"), "").trim()
    return core(a) == core(b)
}

private fun fold(text: String) =
    Normalizer.normalize(text, Normalizer.Form.NFD).replace(Regex("\\p{Mn}+"), "").lowercase()

/** The name with the typed text in bold, ignoring case and accents. */
private fun highlighted(name: String, query: String): AnnotatedString {
    val needle = fold(query.trim())
    val start = if (needle.isEmpty()) -1 else fold(name).indexOf(needle)
    if (start < 0 || fold(name).length != name.length) return AnnotatedString(name)
    return buildAnnotatedString {
        append(name.substring(0, start))
        withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append(name.substring(start, start + needle.length)) }
        append(name.substring(start + needle.length))
    }
}
