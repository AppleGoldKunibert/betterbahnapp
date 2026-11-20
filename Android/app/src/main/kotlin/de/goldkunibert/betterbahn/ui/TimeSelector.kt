@file:OptIn(ExperimentalMaterial3Api::class)

package de.goldkunibert.betterbahn.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimePicker
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZoneOffset

/** A chip with the chosen time ("Jetzt", "14:05", "Mo., 3. Nov., 14:05"); a tap picks day and time (`TimeSelector`). */
@Composable
fun TimeSelector(time: Long?, onChange: (Long?) -> Unit, modifier: Modifier = Modifier) {
    var picking by remember { mutableStateOf(false) }
    AssistChip(
        onClick = { picking = true },
        label = { Text(searchTimeLabel(time)) },
        leadingIcon = { Icon(Icons.Filled.Schedule, null) },
        modifier = modifier,
    )
    if (picking) DateTimeDialog(time, onDone = { onChange(it); picking = false }, onDismiss = { picking = false })
}

/** Day first, then the time; "Jetzt" goes back to now. */
@Composable
fun DateTimeDialog(initial: Long?, onDone: (Long?) -> Unit, onDismiss: () -> Unit) {
    val zone = ZoneId.systemDefault()
    val start = Instant.ofEpochMilli(initial ?: System.currentTimeMillis()).atZone(zone)
    var day by remember { mutableStateOf<LocalDate?>(null) }
    val dateState = rememberDatePickerState(
        initialSelectedDateMillis = start.toLocalDate().atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli(),
    )
    val timeState = rememberTimePickerState(start.hour, start.minute, is24Hour = true)

    if (day == null) {
        DatePickerDialog(
            onDismissRequest = onDismiss,
            confirmButton = {
                TextButton(onClick = {
                    day = dateState.selectedDateMillis?.let { Instant.ofEpochMilli(it).atZone(ZoneOffset.UTC).toLocalDate() }
                        ?: start.toLocalDate()
                }) { Text("Weiter") }
            },
            dismissButton = { TextButton(onClick = { onDone(null) }) { Text("Jetzt") } },
        ) { DatePicker(dateState) }
    } else {
        AlertDialog(
            onDismissRequest = onDismiss,
            confirmButton = {
                TextButton(onClick = {
                    val chosen = day!!.atTime(LocalTime.of(timeState.hour, timeState.minute)).atZone(zone)
                    onDone(chosen.toInstant().toEpochMilli())
                }) { Text("Fertig") }
            },
            dismissButton = { TextButton(onClick = { onDone(null) }) { Text("Jetzt") } },
            text = { Row(horizontalArrangement = Arrangement.Center) { TimePicker(timeState) } },
        )
    }
}

/** For screens that need a little spacing between chips. */
val ChipSpacing = 8.dp
