package de.goldkunibert.betterbahn.ui

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.roundToInt

// The iOS app's formats (BetterBahn/Shared/DesignSystem.swift), in the device's time zone.

private val german = Locale.GERMANY
private val timeFormat = DateTimeFormatter.ofPattern("HH:mm", german)
private val dayFormat = DateTimeFormatter.ofPattern("EEE, d. MMM", german)
private val longDayFormat = DateTimeFormatter.ofPattern("EEEE, d. MMMM", german)

private fun local(millis: Long) = Instant.ofEpochMilli(millis).atZone(ZoneId.systemDefault())

fun timeString(millis: Long): String = local(millis).format(timeFormat)

/** "45 min", "2 h", "1 h 05 min". */
fun durationString(seconds: Double): String {
    val minutes = (seconds / 60).roundToInt()
    if (minutes >= 60 && minutes % 60 == 0) return "${minutes / 60} h"
    return if (minutes >= 60) "${minutes / 60} h ${"%02d".format(minutes % 60)} min" else "$minutes min"
}

/** "45 min", "2 h", "1:05 h". */
fun compactDuration(seconds: Double): String {
    val minutes = (seconds / 60).roundToInt()
    if (minutes >= 60 && minutes % 60 == 0) return "${minutes / 60} h"
    return if (minutes >= 60) "${minutes / 60}:${"%02d".format(minutes % 60)} h" else "$minutes min"
}

/** "Heute", "Morgen", else "Mo., 3. Nov.". */
fun dayLabel(millis: Long, long: Boolean = false): String {
    val date = local(millis).toLocalDate()
    val today = LocalDate.now()
    return when (date) {
        today -> "Heute"
        today.plusDays(1) -> "Morgen"
        today.minusDays(1) -> "Gestern"
        else -> date.format(if (long) longDayFormat else dayFormat)
    }
}

/** The search time as the time selector shows it: "Jetzt", "14:05" today, else "Mo., 3. Nov., 14:05". */
fun searchTimeLabel(millis: Long?): String {
    millis ?: return "Jetzt"
    val date = local(millis).toLocalDate()
    return if (date == LocalDate.now()) timeString(millis) else "${local(millis).format(dayFormat)}, ${timeString(millis)}"
}

fun transfersText(transfers: Int): String = when (transfers) {
    0 -> "Direkt"
    1 -> "1 Umstieg"
    else -> "$transfers Umstiege"
}
