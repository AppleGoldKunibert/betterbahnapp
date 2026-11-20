package de.goldkunibert.betterbahn.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.border
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.PathOperation
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.layout.onPlaced
import androidx.compose.ui.layout.positionInParent
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.goldkunibert.betterbahn.data.AppDesign

// The Fahrkarte design (iOS `AppDesign.fahrkarte`, ConnectionsTicketViews.swift): the search and its results as
// tickets, notched at each perforation, on a warm page.

/** The design chosen in the settings, for every screen below (`\.appDesign` on iOS). */
val LocalAppDesign = compositionLocalOf { AppDesign.Minimal }

@Composable
fun ProvideAppDesign(design: AppDesign, content: @Composable () -> Unit) =
    CompositionLocalProvider(LocalAppDesign provides design, content = content)

val isFahrkarte: Boolean @Composable get() = LocalAppDesign.current == AppDesign.Fahrkarte

/** The ticket's surface: white (dark grey) tinted a little towards the brand colour (`Color.ticket`). */
val ticketColor: Color
    @Composable get() = lerp(if (isSystemInDarkTheme()) Color(0xFF1C1C1C) else Color.White, Brand, 0.035f)

/** Fahrkarte's page: a warm off-white, near black in dark mode (`Color.canvas`). */
val canvasColor: Color
    @Composable get() = if (isSystemInDarkTheme()) Color(0xFF0D0D0F) else Color(0xFFF5F4F1)

/** A thin outline (`Color.hairline`). */
val hairlineColor: Color @Composable get() = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f)

/** The page behind a screen: Fahrkarte's warm page, else the grouped grey. */
val pageColor: Color @Composable get() = if (isFahrkarte) canvasColor else MaterialTheme.colorScheme.background

/** A rounded rectangle with a half-circle cut into both sides at each of [notches] (y, px) (`TicketShape`). */
class TicketShape(private val notches: List<Float>, private val notchRadius: Dp = 10.dp, private val cornerRadius: Dp = 22.dp) : Shape {
    override fun createOutline(size: Size, layoutDirection: LayoutDirection, density: Density): Outline {
        val r = with(density) { notchRadius.toPx() }
        val c = with(density) { cornerRadius.toPx() }
        val body = Path().apply { addRoundRect(RoundRect(Rect(Offset.Zero, size), CornerRadius(c))) }
        // Notches that would run into a corner (while the layout settles) are left out.
        val cuts = Path()
        notches.filter { it - r > c && it + r < size.height - c }.forEach { y ->
            cuts.addOval(Rect(Offset(0f, y), r))
            cuts.addOval(Rect(Offset(size.width, y), r))
        }
        return Outline.Generic(Path().apply { op(body, cuts, PathOperation.Difference) })
    }
}

/**
 * A ticket: [sections] one below the other, a dashed perforation between them with notches at its ends
 * (`.ticketBackground()` with `TicketPerforation`).
 */
@Composable
fun Ticket(modifier: Modifier = Modifier, sections: List<@Composable () -> Unit>) {
    val notches = remember { mutableStateMapOf<Int, Float>() }
    val shape = TicketShape(notches.entries.sortedBy { it.key }.map { it.value })
    Column(
        modifier
            .fillMaxWidth()
            .clip(shape)
            .background(ticketColor)
            .border(1.dp, hairlineColor, shape),
    ) {
        sections.forEachIndexed { index, section ->
            if (index > 0) {
                Perforation(Modifier.onPlaced { notches[index] = it.positionInParent().y })
            }
            section()
        }
    }
}

/** The dashed line between a ticket's parts (`TicketPerforation`). */
@Composable
fun Perforation(modifier: Modifier = Modifier) {
    val color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.2f)
    Canvas(modifier.fillMaxWidth().padding(horizontal = 18.dp).height(1.5.dp)) {
        drawLine(
            color, Offset(0f, size.height / 2), Offset(size.width, size.height / 2), strokeWidth = size.height,
            cap = StrokeCap.Round, pathEffect = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 5.dp.toPx())),
        )
    }
}

/** A ticket's small upper-case label: "VON", "ABFAHRT" (`TicketCaption`). */
@Composable
fun TicketCaption(text: String, modifier: Modifier = Modifier) {
    Text(
        text.uppercase(), modifier, style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.SemiBold,
        letterSpacing = 0.6.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1,
    )
}

/** A labelled value on a ticket, e.g. "VON" over the station (`TicketValueField`). */
@Composable
fun TicketValueField(label: String, value: String, modifier: Modifier = Modifier) {
    Column(modifier) {
        TicketCaption(label)
        Text(value, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, maxLines = 2, overflow = TextOverflow.Ellipsis)
    }
}

/** A card in the chosen design: Minimal a plain card, Fahrkarte a flat outlined ticket-coloured one (`Card`). */
@Composable
fun DesignCard(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    val shape = androidx.compose.foundation.shape.RoundedCornerShape(22.dp)
    val fahrkarte = isFahrkarte
    Column(
        modifier
            .fillMaxWidth()
            .clip(shape)
            .background(if (fahrkarte) ticketColor else MaterialTheme.colorScheme.surfaceContainerLowest)
            .border(if (fahrkarte) 1.dp else 0.5.dp, hairlineColor, shape),
    ) { content() }
}
