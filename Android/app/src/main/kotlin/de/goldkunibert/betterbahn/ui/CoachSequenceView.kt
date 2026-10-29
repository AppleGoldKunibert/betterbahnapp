package de.goldkunibert.betterbahn.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.automirrored.filled.Accessible
import androidx.compose.material.icons.filled.ChildCare
import androidx.compose.material.icons.filled.EventSeat
import androidx.compose.material.icons.filled.FamilyRestroom
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.PedalBike
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.automirrored.filled.VolumeOff
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import de.goldkunibert.betterbahn.kit.Coach
import de.goldkunibert.betterbahn.kit.CoachSequence
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

private val dateFormat = DateTimeFormatter.ofPattern("dd.MM.yyyy")
private fun date(millis: Long) = Instant.ofEpochMilli(millis).atZone(ZoneId.systemDefault()).format(dateFormat)

/**
 * vagonweb's planned Wagenreihung (`CoachSequenceView` for a plan on iOS): the coaches front first, with class,
 * dining car and amenities, the direction when known, and where the plan comes from.
 */
@Composable
fun CoachSequenceView(sequence: CoachSequence) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        when (sequence.travelsTowardsPlatformEnd) {
            true -> DirectionLabel(towardsEnd = true)
            false -> DirectionLabel(towardsEnd = false)
            null -> {}
        }
        val showParts = sequence.groups.count { !it.isLocomotiveOnly } > 1
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            sequence.coaches.forEachIndexed { index, coach ->
                val group = sequence.groups.getOrNull(coach.group)
                val startsPart = showParts && (index == 0 || sequence.coaches[index - 1].group != coach.group) && group?.isLocomotiveOnly == false
                Column {
                    Text(
                        if (startsPart) listOfNotNull(group.trainName, group.destination?.let { "→ $it" }).joinToString(" ") else "",
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.Bold,
                        color = Brand,
                        maxLines = 1,
                        modifier = Modifier.width(56.dp).height(16.dp),
                    )
                    CoachBox(coach)
                }
            }
        }
        val validity = if (sequence.validFrom != null && sequence.validUntil != null) "gilt ${date(sequence.validFrom)} – ${date(sequence.validUntil)}" else null
        Text("Plan-Wagenreihung – kann abweichen", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(
            listOfNotNull("Ohne Gleisabschnitte", validity, "Daten: vagonweb.cz").joinToString(" · "),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        when {
            sequence.travelsTowardsPlatformEnd == null -> Text("Fahrtrichtung unbekannt", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            sequence.reversals.isNotEmpty() -> Text(
                "Fahrtrichtungswechsel in ${sequence.reversals.joinToString(", ")}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/** "← Richtung" at the left or "Richtung →" at the right: where the train leaves to. */
@Composable
private fun DirectionLabel(towardsEnd: Boolean) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = if (towardsEnd) Arrangement.End else Arrangement.Start, verticalAlignment = Alignment.CenterVertically) {
        if (!towardsEnd) Icon(Icons.AutoMirrored.Filled.ArrowBack, null, Modifier.size(14.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Text("Richtung", style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (towardsEnd) Icon(Icons.AutoMirrored.Filled.ArrowForward, null, Modifier.size(14.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun CoachBox(coach: Coach) {
    val fill: Color = when (coach.kind) {
        "locomotive", "powerCar" -> Color.Gray
        "diningCar", "halfDiningCar" -> Brand
        else -> if (coach.firstClass) Color(0xFFF2B705) else MaterialTheme.colorScheme.onSurfaceVariant
    }
    val shape = RoundedCornerShape(if (coach.isPassengerCoach) 6.dp else 12.dp)
    Column(
        Modifier.width(56.dp).height(84.dp).alpha(if (coach.closed) 0.5f else 1f)
            .background(fill.copy(alpha = if (coach.isPassengerCoach) 0.22f else 0.45f), shape)
            .border(1.dp, fill.copy(alpha = 0.6f), shape)
            .padding(4.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (coach.closed) Icon(Icons.Filled.Lock, "Geschlossen", Modifier.size(10.dp))
            Text(coach.number ?: "", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
        }
        caption(coach)?.let { Text(it, style = MaterialTheme.typography.labelSmall, maxLines = 1) }
        Box(Modifier.weight(1f), contentAlignment = Alignment.BottomCenter) {
            Row(horizontalArrangement = Arrangement.spacedBy(1.dp), verticalAlignment = Alignment.CenterVertically) {
                val bikes = "BIKE_SPACE" in coach.amenities
                if (bikes) {
                    Icon(Icons.Filled.PedalBike, "Fahrräder", Modifier.size(12.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    coach.bikeSpaces?.let { Text("$it", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                }
                coach.amenities.filter { it != "BIKE_SPACE" }.mapNotNull { amenityIcon(it) }.distinct().take(if (bikes) 2 else 3).forEach { icon ->
                    Icon(icon, null, Modifier.size(12.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
}

/** As on iOS: "Bistro", "Speisewagen" …, else the classes. */
private fun caption(coach: Coach): String? = when (coach.kind) {
    "diningCar" -> "Speisew."
    "halfDiningCar" -> "Bistro"
    "sleeper" -> "Schlafw."
    "couchette" -> "Liegew."
    "locomotive", "powerCar" -> "Lok"
    else -> when {
        coach.firstClass && coach.secondClass -> "1./2."
        coach.firstClass -> "1. Kl."
        coach.secondClass -> "2. Kl."
        else -> null
    }
}

private fun amenityIcon(amenity: String): ImageVector? = when (amenity) {
    "BIKE_SPACE" -> Icons.Filled.PedalBike
    "WHEELCHAIR_SPACE", "TOILET_WHEELCHAIR" -> Icons.AutoMirrored.Filled.Accessible
    "SEATS_SEVERELY_DISABLED" -> Icons.Filled.EventSeat
    "ZONE_QUIET" -> Icons.AutoMirrored.Filled.VolumeOff
    "ZONE_FAMILY" -> Icons.Filled.FamilyRestroom
    "CABIN_INFANT" -> Icons.Filled.ChildCare
    "SEATS_BAHN_COMFORT" -> Icons.Filled.Star
    "INFO" -> Icons.Filled.Info
    else -> null
}
