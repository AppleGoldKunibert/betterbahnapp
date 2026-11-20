@file:OptIn(ExperimentalMaterial3Api::class)

package de.goldkunibert.betterbahn.ui.connections

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Place
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.SwapVert
import androidx.compose.material.icons.filled.Train
import androidx.compose.material.icons.filled.TripOrigin
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import de.goldkunibert.betterbahn.AppModel
import de.goldkunibert.betterbahn.Route
import de.goldkunibert.betterbahn.SearchForm
import de.goldkunibert.betterbahn.data.BikeOption
import de.goldkunibert.betterbahn.data.ConnectionSearch
import de.goldkunibert.betterbahn.kit.Product
import de.goldkunibert.betterbahn.kit.TicketType
import de.goldkunibert.betterbahn.ui.DesignCard
import de.goldkunibert.betterbahn.ui.ProductFilterSheet
import de.goldkunibert.betterbahn.ui.StationPicker
import de.goldkunibert.betterbahn.ui.Ticket
import de.goldkunibert.betterbahn.ui.TicketCaption
import de.goldkunibert.betterbahn.ui.TimeSelector
import de.goldkunibert.betterbahn.ui.isFahrkarte
import de.goldkunibert.betterbahn.ui.productSummary

/** Which station field the picker fills: start, destination, or the via station at that index. */
private sealed interface Field {
    data object From : Field
    data object To : Field
    data class Via(val index: Int) : Field
}

/** As on iOS: up to four stations to pass through. */
private const val MAX_VIA = 4

/**
 * The connection search (`ConnectionsView`). Minimal: the route in a card, then the time and one row that unfolds
 * the rarely changed options. Fahrkarte: route and time on one ticket, the options in their own card below. Then
 * "Deine Reisen" and "Zuletzt gesucht".
 */
@Composable
fun ConnectionsScreen(model: AppModel) {
    val form = model.form
    val settings = model.store.settings
    var picking by remember { mutableStateOf<Field?>(null) }
    var filtering by remember { mutableStateOf(false) }
    var stayFor by remember { mutableStateOf<Int?>(null) }
    var showsOptions by remember { mutableStateOf(false) }
    val recentSearches by model.store.recentSearches.collectAsState()
    val recentExpanded by settings.recentSearchesExpanded.state.collectAsState()
    val ticket by model.store.ticketType.collectAsState()
    val bike by settings.bikeOption.state.collectAsState()
    val withBike by settings.searchWithBike.state.collectAsState()
    val fahrkarte = isFahrkarte

    fun search(search: ConnectionSearch) {
        model.store.rememberSearch(search.from, search.to)
        model.push(Route.Results(search))
    }

    fun update(change: (SearchForm) -> SearchForm) {
        model.form = change(model.form)
    }

    val options = OptionsState(
        form = form, ticket = ticket, bike = bike, withBike = withBike && bike != BikeOption.Hidden,
        onTicket = { on -> update { it.copy(onlyValidTicket = on) } },
        onBike = { settings.searchWithBike.set(it) },
        onMaxTransfers = { value -> update { it.copy(maxTransfers = value) } },
        onProducts = { filtering = true },
    )

    Column(Modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text("Verbindungen") },
            actions = {
                IconButton(onClick = { model.push(Route.TrainSearch()) }) { Icon(Icons.Filled.Train, "Zug suchen") }
            },
            colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent),
        )
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (fahrkarte) {
                Text("Wohin geht’s?", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
                Ticket(sections = listOf(
                    { RouteFields(form, ticketStyle = true, onPick = { picking = it }, onStay = { stayFor = it }, onUpdate = ::update) },
                    { Box(Modifier.padding(16.dp)) { TimeSection(form, ::update) } },
                ))
                DesignCard { Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) { OptionRows(options) } }
            } else {
                DesignCard { RouteFields(form, ticketStyle = false, onPick = { picking = it }, onStay = { stayFor = it }, onUpdate = ::update) }
                DesignCard {
                    Box(Modifier.padding(16.dp)) { TimeSection(form, ::update) }
                    HorizontalDivider(Modifier.padding(start = 16.dp))
                    Row(
                        Modifier.fillMaxWidth().clickable { showsOptions = !showsOptions }.padding(horizontal = 16.dp, vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        OptionLabel(Icons.Filled.Tune, "Optionen", options.summary ?: "Keine Einschränkungen", Modifier.weight(1f))
                        Icon(Icons.Filled.ExpandMore, if (showsOptions) "Optionen ausblenden" else "Optionen einblenden",
                            Modifier.rotate(if (showsOptions) 180f else 0f), tint = MaterialTheme.colorScheme.outline)
                    }
                    AnimatedVisibility(showsOptions) {
                        Column(Modifier.padding(start = 16.dp, end = 16.dp, bottom = 16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                            OptionRows(options)
                        }
                    }
                }
            }
            Button(
                onClick = { form.search(withBike = withBike && bike != BikeOption.Hidden)?.let(::search) },
                enabled = form.from != null && form.to != null && !form.hasEmptyProductSelection,
                modifier = Modifier.fillMaxWidth().height(52.dp),
            ) {
                Icon(Icons.Filled.Search, null, Modifier.padding(end = 8.dp))
                Text("Verbindungen suchen", fontWeight = FontWeight.SemiBold)
            }

            Spacer(Modifier.height(4.dp))
            SavedTripsSection(model)

            if (recentSearches.isNotEmpty()) {
                Row(
                    Modifier.fillMaxWidth().padding(top = 8.dp).clickable { settings.recentSearchesExpanded.set(!recentExpanded) },
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    SectionTitle("Zuletzt gesucht", trailing = recentSearches.size.toString(), modifier = Modifier.weight(1f))
                    Icon(Icons.Filled.ExpandMore, if (recentExpanded) "Einklappen" else "Ausklappen",
                        Modifier.rotate(if (recentExpanded) 180f else 0f), tint = MaterialTheme.colorScheme.outline)
                }
                AnimatedVisibility(recentExpanded) {
                    DesignCard {
                        recentSearches.forEachIndexed { index, recent ->
                            if (index > 0) HorizontalDivider(Modifier.padding(start = 16.dp))
                            var menu by remember { mutableStateOf(false) }
                            Box {
                                Row(
                                    Modifier.fillMaxWidth()
                                        .combinedClickable(
                                            onClick = {
                                                model.form = form.copy(from = recent.from, to = recent.to).withVia(emptyList(), emptyList(), emptyList())
                                                model.form.search(withBike = withBike && bike != BikeOption.Hidden)?.let(::search)
                                            },
                                            onLongClick = { menu = true },
                                        )
                                        .padding(horizontal = 16.dp, vertical = 14.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                                ) {
                                    Text(recent.from.shownName, Modifier.weight(1f, fill = false), maxLines = 1, overflow = TextOverflow.Ellipsis)
                                    Icon(Icons.AutoMirrored.Filled.ArrowForward, null, Modifier.size(16.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                                    Text(recent.to.shownName, Modifier.weight(1f, fill = false), maxLines = 1, overflow = TextOverflow.Ellipsis)
                                }
                                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                                    DropdownMenuItem(text = { Text("Entfernen") }, onClick = { menu = false; model.store.removeSearch(recent) })
                                }
                            }
                        }
                    }
                }
            }
            Spacer(Modifier.height(24.dp))
        }
    }

    picking?.let { field ->
        StationPicker(
            store = model.store,
            placeholder = when (field) {
                Field.From -> "Von wo?"
                Field.To -> "Wohin?"
                is Field.Via -> "Über welchen Ort?"
            },
            onPick = { station ->
                update { current ->
                    when (field) {
                        Field.From -> current.copy(from = station)
                        Field.To -> current.copy(to = station)
                        is Field.Via -> if (field.index < current.via.size) {
                            current.copy(via = current.via.toMutableList().apply { set(field.index, station) })
                        } else {
                            current.withVia(
                                current.via + station,
                                current.via.indices.map(current::stay) + 0,
                                (0..current.via.size).map(current::legProducts) + listOf(Product.all),
                            )
                        }
                    }
                }
                picking = null
            },
            onDismiss = { picking = null },
        )
    }
    if (filtering) {
        ProductFilterSheet(
            products = form.products,
            onChange = { products -> update { it.copy(products = products) } },
            onDismiss = { filtering = false },
            sections = if (form.via.isEmpty()) emptyList() else sectionTitles(form),
            perSection = form.productsPerLeg,
            onPerSection = { on -> update { it.copy(productsPerLeg = on) } },
            sectionProducts = { form.legProducts(it) },
            onSectionChange = { index, products ->
                update { current ->
                    current.copy(legProducts = (0..current.via.size).map { if (it == index) products else current.legProducts(it) })
                }
            },
        )
    }
    stayFor?.let { index ->
        MinimumStayDialog(form.via.getOrNull(index)?.shownName.orEmpty(), form.stay(index), onDone = { minutes ->
            update { current -> current.copy(viaStays = current.via.indices.map { if (it == index) minutes else current.stay(it) }) }
            stayFor = null
        }, onDismiss = { stayFor = null })
    }
}

/** The parts of the route between consecutive stops: "Start → Halt", … */
private fun sectionTitles(form: SearchForm): List<String> {
    val names = listOf(form.from?.shownName ?: "Start") + form.via.map { it.shownName } + listOf(form.to?.shownName ?: "Ziel")
    return names.zipWithNext { a, b -> "$a → $b" }
}

/**
 * Start, via stations and destination. Minimal: rows with an icon. Fahrkarte: "Von"/"Nach" labels along a route
 * line. Swapping start and destination sits beside them; up to four via stations, each with a minimum stay.
 */
@Composable
private fun RouteFields(
    form: SearchForm, ticketStyle: Boolean, onPick: (Field) -> Unit, onStay: (Int) -> Unit, onUpdate: ((SearchForm) -> SearchForm) -> Unit,
) {
    Box {
        Column(Modifier.padding(vertical = 4.dp)) {
            StationField(if (ticketStyle) "Von" else "Start", form.from?.shownName, "Von wo?", Icons.Filled.TripOrigin, ticketStyle, RouteMark.First) { onPick(Field.From) }
            form.via.forEachIndexed { index, station ->
                FieldDivider()
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.weight(1f)) {
                        StationField("Zwischenhalt", station.shownName, "Über welchen Ort?", Icons.Filled.Place, ticketStyle, RouteMark.Middle) { onPick(Field.Via(index)) }
                    }
                    val stay = form.stay(index)
                    AssistChip(onClick = { onStay(index) }, label = { Text(if (stay > 0) "Mind. $stay Min." else "Mindestaufenthalt", maxLines = 1) })
                    IconButton(onClick = { onUpdate { it.removingVia(index) } }) { Icon(Icons.Filled.Close, "Zwischenhalt entfernen") }
                }
            }
            FieldDivider()
            StationField(if (ticketStyle) "Nach" else "Ziel", form.to?.shownName, "Wohin?", Icons.Filled.Place, ticketStyle, RouteMark.Last) { onPick(Field.To) }
            if (form.via.size < MAX_VIA) {
                TextButton(onClick = { onPick(Field.Via(form.via.size)) }, modifier = Modifier.padding(start = 40.dp)) {
                    Icon(Icons.Filled.Add, null, Modifier.padding(end = 6.dp))
                    Text(if (ticketStyle) "Zwischenhalt" else "Zwischenhalt hinzufügen")
                }
            }
        }
        FilledTonalIconButton(
            onClick = { onUpdate { it.copy(from = it.to, to = it.from) } },
            enabled = form.from != null || form.to != null,
            modifier = Modifier.align(Alignment.TopEnd).padding(top = 40.dp, end = 12.dp),
        ) { Icon(Icons.Filled.SwapVert, "Start und Ziel tauschen") }
    }
}

@Composable
private fun FieldDivider() = HorizontalDivider(Modifier.padding(start = 56.dp, end = 64.dp))

/** Where a field sits on the Fahrkarte's route line. */
private enum class RouteMark { First, Middle, Last }

@Composable
private fun StationField(
    label: String, value: String?, placeholder: String, icon: ImageVector, ticketStyle: Boolean, mark: RouteMark, onClick: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(start = 16.dp, end = 64.dp, top = 10.dp, bottom = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (ticketStyle) RouteMarker(mark) else Icon(icon, null, Modifier.size(24.dp), tint = MaterialTheme.colorScheme.primary)
        Spacer(Modifier.width(16.dp))
        Column {
            if (ticketStyle) TicketCaption(label) else Text(label, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(
                value ?: placeholder,
                style = if (ticketStyle) MaterialTheme.typography.titleLarge else MaterialTheme.typography.bodyLarge,
                fontWeight = if (ticketStyle && value != null) FontWeight.Bold else null,
                color = if (value == null) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface,
                maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

/** Fahrkarte: a stop on the vertical route line, the line running on to the next field. */
@Composable
private fun RouteMarker(mark: RouteMark) {
    val color = MaterialTheme.colorScheme.primary
    val line = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.25f)
    Canvas(Modifier.size(24.dp, 44.dp)) {
        val x = size.width / 2
        val dash = PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 4.dp.toPx()))
        if (mark != RouteMark.First) drawLine(line, Offset(x, -12.dp.toPx()), Offset(x, size.height / 2), 2.dp.toPx(), StrokeCap.Round, dash)
        if (mark != RouteMark.Last) drawLine(line, Offset(x, size.height / 2), Offset(x, size.height + 12.dp.toPx()), 2.dp.toPx(), StrokeCap.Round, dash)
        if (mark == RouteMark.Middle) {
            drawCircle(color, 4.dp.toPx(), Offset(x, size.height / 2))
        } else {
            drawCircle(color, 7.dp.toPx(), Offset(x, size.height / 2))
            drawCircle(Color.White, 3.dp.toPx(), Offset(x, size.height / 2))
        }
    }
}

/** Departure or arrival and the time; with via stations only by departure. */
@Composable
private fun TimeSection(form: SearchForm, onUpdate: ((SearchForm) -> SearchForm) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            SingleChoiceSegmentedButtonRow(Modifier.weight(1f)) {
                listOf("Abfahrt" to false, "Ankunft" to true).forEachIndexed { index, (label, arrival) ->
                    SegmentedButton(
                        selected = (form.isArrival && form.via.isEmpty()) == arrival,
                        onClick = { onUpdate { it.copy(isArrival = arrival) } },
                        enabled = form.via.isEmpty(),
                        shape = SegmentedButtonDefaults.itemShape(index, 2),
                    ) { Text(label) }
                }
            }
            Spacer(Modifier.width(12.dp))
            TimeSelector(form.date, onChange = { date -> onUpdate { it.copy(date = date) } })
        }
        if (form.via.isNotEmpty()) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(Icons.Filled.Info, null, Modifier.size(14.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                Text("Mit Zwischenhalten suchen wir ab der gewählten Abfahrtszeit.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

/** What the option rows show and change. */
private class OptionsState(
    val form: SearchForm,
    val ticket: TicketType,
    val bike: BikeOption,
    val withBike: Boolean,
    val onTicket: (Boolean) -> Unit,
    val onBike: (Boolean) -> Unit,
    val onMaxTransfers: (Int?) -> Unit,
    val onProducts: () -> Unit,
) {
    val productText: String get() = if (form.perLeg) "Pro Abschnitt festgelegt" else productSummary(form.products)

    /** The options that differ from the defaults, or null when none do (`optionsSummary`). */
    val summary: String?
        get() {
            val parts = buildList {
                if (form.onlyValidTicket) add(ticket.shortName)
                if (withBike) bike.searchTitle?.let(::add)
                form.maxTransfers?.let { add(if (it == 0) "Direkt" else "Max. $it Umstiege") }
                if (form.perLeg || form.products != Product.all) add(productText)
            }
            return parts.takeIf { it.isNotEmpty() }?.joinToString(" · ")
        }
}

/** The ticket filter, the bike, the transfers and the products (`optionRows`). */
@Composable
private fun OptionRows(options: OptionsState) {
    val form = options.form
    Row(verticalAlignment = Alignment.CenterVertically) {
        OptionLabel(null, options.ticket.filterTitle, options.ticket.filterSubtitle, Modifier.weight(1f))
        Switch(checked = form.onlyValidTicket, onCheckedChange = options.onTicket)
    }
    options.bike.searchTitle?.let { title ->
        Row(verticalAlignment = Alignment.CenterVertically) {
            OptionLabel(null, title, options.bike.searchSubtitle, Modifier.weight(1f))
            Switch(checked = options.withBike, onCheckedChange = options.onBike)
        }
    }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        OptionLabel(null, "Max. Umstiege", "Weniger Umsteigen, evtl. länger unterwegs")
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
            val choices = listOf("Beliebig" to null, "Direkt" to 0, "≤ 1" to 1, "≤ 2" to 2)
            choices.forEachIndexed { index, (label, value) ->
                SegmentedButton(
                    selected = form.maxTransfers == value,
                    onClick = { options.onMaxTransfers(value) },
                    shape = SegmentedButtonDefaults.itemShape(index, choices.size),
                ) { Text(label) }
            }
        }
    }
    Row(Modifier.fillMaxWidth().clickable(onClick = options.onProducts), verticalAlignment = Alignment.CenterVertically) {
        OptionLabel(null, "Verkehrsmittel", options.productText, Modifier.weight(1f))
        Icon(Icons.AutoMirrored.Filled.ArrowForward, null, Modifier.size(16.dp), tint = MaterialTheme.colorScheme.outline)
    }
}

@Composable
private fun OptionLabel(icon: ImageVector?, title: String, subtitle: String?, modifier: Modifier = Modifier) {
    Row(modifier, verticalAlignment = Alignment.CenterVertically) {
        icon?.let { Icon(it, null, Modifier.padding(end = 12.dp).size(20.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant) }
        Column {
            Text(title)
            subtitle?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2, overflow = TextOverflow.Ellipsis) }
        }
    }
}

/** "Mindestaufenthalt in …": how long to stay at a via station at least, in steps of 5 minutes. */
@Composable
private fun MinimumStayDialog(station: String, current: Int, onDone: (Int) -> Unit, onDismiss: () -> Unit) {
    var minutes by remember { mutableStateOf(current) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Mindestaufenthalt in $station") },
        text = {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.Center, modifier = Modifier.fillMaxWidth()) {
                TextButton(onClick = { minutes = (minutes - 5).coerceAtLeast(0) }, enabled = minutes > 0) { Text("−", style = MaterialTheme.typography.headlineSmall) }
                Text(if (minutes == 0) "Keiner" else "$minutes Min.", Modifier.width(120.dp), style = MaterialTheme.typography.titleLarge,
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                TextButton(onClick = { minutes = (minutes + 5).coerceAtMost(24 * 60) }) { Text("+", style = MaterialTheme.typography.headlineSmall) }
            }
        },
        confirmButton = { TextButton(onClick = { onDone(minutes) }) { Text("Fertig") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Abbrechen") } },
    )
}
