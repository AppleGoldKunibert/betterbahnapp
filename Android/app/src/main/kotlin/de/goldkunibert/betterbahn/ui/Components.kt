package de.goldkunibert.betterbahn.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.DirectionsWalk
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.DirectionsBoat
import androidx.compose.material.icons.filled.DirectionsBus
import androidx.compose.material.icons.filled.DirectionsRailway
import androidx.compose.material.icons.filled.DirectionsSubway
import androidx.compose.material.icons.automirrored.filled.Help
import androidx.compose.material.icons.filled.Hotel
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Train
import androidx.compose.material.icons.filled.Tram
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.goldkunibert.betterbahn.kit.LineDisplay
import de.goldkunibert.betterbahn.kit.PlatformInfo
import de.goldkunibert.betterbahn.kit.Product
import de.goldkunibert.betterbahn.kit.TimeInfo

// The iOS app's shared transit components (BetterBahn/Shared/DesignSystem.swift).

fun productIcon(product: Product, nightTrain: Boolean = false): ImageVector = when {
    nightTrain -> Icons.Filled.Hotel
    else -> when (product) {
        Product.HighSpeed, Product.LongDistance, Product.NightTrain, Product.Interregio -> Icons.Filled.Train
        Product.RegionalExpress, Product.Regional, Product.Suburban -> Icons.Filled.DirectionsRailway
        Product.Subway -> Icons.Filled.DirectionsSubway
        Product.Tram -> Icons.Filled.Tram
        Product.Bus, Product.Coach -> Icons.Filled.DirectionsBus
        Product.Ferry -> Icons.Filled.DirectionsBoat
        Product.Other -> Icons.AutoMirrored.Filled.Help
    }
}

/** Capsule in the line's colour with its symbol and name; "Fußweg" for a walk. */
@Composable
fun LineBadge(line: LineDisplay?, modifier: Modifier = Modifier, small: Boolean = false) {
    val style = if (small) MaterialTheme.typography.labelSmall else MaterialTheme.typography.labelMedium
    if (line == null) {
        Row(
            modifier.background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f), CircleShape)
                .padding(horizontal = 8.dp, vertical = 3.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.AutoMirrored.Filled.DirectionsWalk, null, Modifier.size(14.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
            Text("Fußweg", style = style, color = MaterialTheme.colorScheme.onSurfaceVariant, fontWeight = FontWeight.Bold)
        }
        return
    }
    Row(
        modifier.background(lineColor(line), CircleShape)
            .padding(horizontal = if (small) 6.dp else 8.dp, vertical = if (small) 2.dp else 3.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        Icon(productIcon(Product.of(line.filterProduct), line.isNightTrain), null, Modifier.size(if (small) 12.dp else 14.dp), tint = Color.White)
        Text(line.displayName, style = style, color = Color.White, fontWeight = FontWeight.Bold, maxLines = 1)
    }
}

/** Planned time with the live time below, coloured by delay; struck through with "Ausfall" when cancelled. */
@Composable
fun TimeStack(time: TimeInfo, cancelled: Boolean = false, alignEnd: Boolean = false, large: Boolean = true) {
    val liveOnTime = time.actual != null && time.delayMinutes == 0
    Column(horizontalAlignment = if (alignEnd) Alignment.End else Alignment.Start) {
        Text(
            timeString(time.planned),
            style = if (large) MaterialTheme.typography.titleMedium else MaterialTheme.typography.bodyMedium,
            fontWeight = FontWeight.SemiBold,
            textDecoration = if (cancelled) TextDecoration.LineThrough else null,
            color = when {
                cancelled -> MaterialTheme.colorScheme.onSurfaceVariant
                liveOnTime -> delayColor(0)
                else -> MaterialTheme.colorScheme.onSurface
            },
        )
        when {
            cancelled -> Text("Ausfall", style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Bold, color = HeavyDelay)
            time.actual != null && !liveOnTime -> Text(
                timeString(time.actual),
                style = MaterialTheme.typography.labelMedium,
                fontWeight = FontWeight.SemiBold,
                color = delayColor(time.delayMinutes),
            )
        }
    }
}

/** "+n min" or "pünktlich" once there is live data. */
@Composable
fun DelayPill(minutes: Int?) {
    minutes ?: return
    val color = delayColor(minutes)
    Row(
        Modifier.background(color.copy(alpha = 0.14f), CircleShape).padding(horizontal = 7.dp, vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        Icon(if (minutes > 0) Icons.Filled.Schedule else Icons.Filled.CheckCircle, null, Modifier.size(12.dp), tint = color)
        Text(if (minutes > 0) "+$minutes min" else "pünktlich", style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Bold, color = color)
    }
}

/** "GLEIS" over the platform, red when it changed. */
@Composable
fun PlatformBadge(platform: PlatformInfo?, prominent: Boolean = false) {
    val best = platform?.best ?: return
    val changed = platform.hasChanged
    val background = if (changed) HeavyDelay else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f)
    val foreground = if (changed) Color.White else MaterialTheme.colorScheme.onSurface
    Column(
        Modifier.widthIn(min = 40.dp).background(background, RoundedCornerShape(8.dp)).padding(horizontal = 6.dp, vertical = 3.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("GLEIS", fontSize = 8.sp, fontWeight = FontWeight.SemiBold, color = foreground.copy(alpha = 0.8f))
        Text(
            if (changed) "$best!" else best,
            style = if (prominent) MaterialTheme.typography.titleMedium else MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.Bold,
            color = foreground,
            maxLines = 1,
        )
    }
}

/** A small rounded label ("Zusatzhalt", "Nur Einstieg" …). */
@Composable
fun Tag(text: String, color: Color = MaterialTheme.colorScheme.onSurfaceVariant) {
    Text(
        text,
        Modifier.background(color.copy(alpha = 0.12f), RoundedCornerShape(6.dp)).padding(horizontal = 6.dp, vertical = 2.dp),
        style = MaterialTheme.typography.labelSmall,
        fontWeight = FontWeight.SemiBold,
        color = color,
    )
}
