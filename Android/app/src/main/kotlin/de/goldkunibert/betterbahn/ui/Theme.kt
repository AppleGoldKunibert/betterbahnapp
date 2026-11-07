package de.goldkunibert.betterbahn.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import de.goldkunibert.betterbahn.kit.LineDisplay
import de.goldkunibert.betterbahn.kit.Product

// The iOS app's colours (BetterBahn/Shared/DesignSystem.swift, Kit Support/ProductStyle.swift).

val Brand = Color(0xFFDB1730)
val BrandDeep = Color(0xFF8C0824)
val Punctual = Color(0xFF219E59)
val SlightDelay = Color(0xFFF28C0D)
val HeavyDelay = Color(0xFFE02633)

// Neutral grey backgrounds with white (dark: elevated grey) cards, like iOS' grouped lists; brand red as accent.
private val LightColors = lightColorScheme(
    primary = Brand,
    onPrimary = Color.White,
    secondary = BrandDeep,
    secondaryContainer = Color(0xFFFBE3E6),
    onSecondaryContainer = BrandDeep,
    background = Color(0xFFF2F2F7),
    surface = Color(0xFFF2F2F7),
    surfaceContainerLowest = Color.White,
    surfaceContainerLow = Color.White,
    surfaceContainer = Color(0xFFF2F2F7),
    surfaceContainerHigh = Color.White,
    surfaceContainerHighest = Color.White,
    surfaceVariant = Color(0xFFE5E5EA),
)
private val DarkColors = darkColorScheme(
    primary = Brand,
    onPrimary = Color.White,
    secondary = Brand,
    secondaryContainer = Color(0xFF4A1018),
    onSecondaryContainer = Color(0xFFFFD9DC),
    background = Color.Black,
    surface = Color.Black,
    surfaceContainerLowest = Color(0xFF1C1C1E),
    surfaceContainerLow = Color(0xFF1C1C1E),
    surfaceContainer = Color(0xFF1C1C1E),
    surfaceContainerHigh = Color(0xFF2C2C2E),
    surfaceContainerHighest = Color(0xFF1C1C1E),
    surfaceVariant = Color(0xFF2C2C2E),
)

@Composable
fun BetterBahnTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = if (isSystemInDarkTheme()) DarkColors else LightColors, content = content)
}

/** Delay colour: green up to 5 minutes late, orange up to 10, red beyond (`delayColor`). */
@Composable
fun delayColor(minutes: Int?): Color = when {
    minutes == null -> MaterialTheme.colorScheme.onSurfaceVariant
    minutes > 10 -> HeavyDelay
    minutes > 5 -> SlightDelay
    else -> Punctual
}

/** How comfortable a transfer is: very short or very long red, a bit tight or a long wait orange (`transferColor`). */
fun transferColor(minutes: Int): Color = when {
    minutes < 5 -> HeavyDelay
    minutes < 15 -> SlightDelay
    minutes < 30 -> Punctual
    minutes < 60 -> SlightDelay
    else -> HeavyDelay
}

@Composable
fun productColor(product: Product): Color = when (product) {
    Product.HighSpeed, Product.LongDistance, Product.NightTrain, Product.Interregio ->
        if (isSystemInDarkTheme()) Color(0xFF6B6B6B) else Color(0xFF1A1A1A)
    Product.RegionalExpress, Product.Regional -> Color(0xFFDB1730)
    Product.Suburban -> Color(0xFF1A994D)
    Product.Bus, Product.Coach -> Color(0xFF8547BD)
    Product.Subway -> Color(0xFF1F61CC)
    Product.Tram -> Color(0xFFCC731A)
    Product.Ferry -> Color(0xFF1A8CCC)
    Product.Other -> Color.Gray
}

/** The line's own colour where it has one (S-Bahn Berlin …), else the product's (`Line.color`). */
@Composable
fun lineColor(line: LineDisplay): Color =
    line.colorHex?.let { Color(0xFF000000 or it) } ?: productColor(Product.of(line.filterProduct))
