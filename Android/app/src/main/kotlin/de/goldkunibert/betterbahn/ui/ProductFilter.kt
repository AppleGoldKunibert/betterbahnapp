@file:OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)

package de.goldkunibert.betterbahn.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.ui.Alignment
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import de.goldkunibert.betterbahn.kit.Product
import de.goldkunibert.betterbahn.kit.TicketType

/** "Alle", "Keine ausgewählt" or the chosen groups (`productSummary`). */
fun productSummary(products: Set<Product>): String = when {
    products == Product.all -> "Alle"
    products.isEmpty() -> "Keine ausgewählt"
    products == Product.trains -> "Nur Züge"
    products == Product.longDistance -> "Nur Fernverkehr"
    else -> Product.entries.filter { it in products }.joinToString(", ") { it.displayName }
}

/** Shortcuts plus one chip per product group (`ProductChips`). */
@Composable
fun ProductFilterSheet(
    products: Set<Product>,
    onChange: (Set<Product>) -> Unit,
    onDismiss: () -> Unit,
    showRegionalShortcut: Boolean = false,
    ticket: TicketType? = null,
    onlyValidTicket: Boolean = false,
    onTicketChange: (Boolean) -> Unit = {},
) {
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.padding(horizontal = 16.dp).padding(bottom = 24.dp).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            ticket?.let {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(it.filterTitle, style = MaterialTheme.typography.titleMedium)
                        Text(it.filterSubtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Switch(checked = onlyValidTicket, onCheckedChange = onTicketChange)
                }
            }
            Text("Verkehrsmittel", style = MaterialTheme.typography.titleMedium)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(ChipSpacing)) {
                FilterChip(products == Product.trains, onClick = { onChange(Product.trains) }, label = { Text("Nur Züge") })
                FilterChip(products == Product.longDistance, onClick = { onChange(Product.longDistance) }, label = { Text("Nur Fernverkehr") })
                if (showRegionalShortcut) {
                    FilterChip(products == Product.regional, onClick = { onChange(Product.regional) }, label = { Text("Nur Regionalverkehr") })
                }
                FilterChip(products == Product.all, onClick = { onChange(Product.all) }, label = { Text("Alle") })
            }
            Text("Züge", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
            ProductChips(Product.entries.filter { it.isTrain }, products, onChange)
            Text("Bus, Tram & Co.", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
            ProductChips(Product.entries.filter { !it.isTrain }, products, onChange)
        }
    }
}

@Composable
private fun ProductChips(shown: List<Product>, products: Set<Product>, onChange: (Set<Product>) -> Unit) {
    FlowRow(horizontalArrangement = Arrangement.spacedBy(ChipSpacing)) {
        for (product in shown) {
            val selected = product in products
            FilterChip(
                selected = selected,
                onClick = { onChange(if (selected) products - product else products + product) },
                label = { Text(product.displayName) },
                leadingIcon = { Icon(productIcon(product), null, Modifier.size(16.dp), tint = productColor(product)) },
            )
        }
    }
}
