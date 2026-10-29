@file:UseSerializers(MillisSerializer::class)

package de.goldkunibert.betterbahn.kit

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.UseSerializers
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.Transient
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlin.math.roundToInt

// BetterBahnKit's models as its Codable JSON has them (Android/kit/Bridge/Methods.swift), only the fields the app
// uses. Dates are milliseconds since 1970. What the iOS app computes with Kit code comes precomputed in the
// `…Display` types; models that go back to the Kit (journeys, legs) keep their JSON as `raw`.

/** Swift writes dates as a double; a fraction of a millisecond must not break decoding. */
object MillisSerializer : KSerializer<Long> {
    override val descriptor = PrimitiveSerialDescriptor("Millis", PrimitiveKind.DOUBLE)
    override fun deserialize(decoder: Decoder): Long = decoder.decodeDouble().toLong()
    override fun serialize(encoder: Encoder, value: Long) = encoder.encodeLong(value)
}

@Serializable
data class Coordinate(val latitude: Double, val longitude: Double)

/** Complete, so the app can store a station and hand it back to the Kit. */
@Serializable
data class Station(
    val id: String,
    val name: String,
    val coordinate: Coordinate? = null,
    val evaNumber: String? = null,
    val source: String,
    val region: String? = null,
    val country: String? = null,
    /** The name the iOS app shows (`Station.displayName`), added by the bridge. */
    val displayName: String? = null,
) {
    val shownName: String get() = displayName ?: name

    /** Loose equality across sources, like `Station.isSamePlace(as:)` for what the picker needs. */
    fun isSamePlace(other: Station): Boolean =
        (source == other.source && id == other.id) ||
            (evaNumber != null && evaNumber == other.evaNumber) ||
            shownName.equals(other.shownName, ignoreCase = true)
}

@Serializable
data class TimeInfo(val planned: Long, val actual: Long? = null) {
    val best: Long get() = actual ?: planned
    val delayMinutes: Int? get() = actual?.let { ((it - planned) / 60_000.0).roundToInt() }
}

@Serializable
data class PlatformInfo(val planned: String? = null, val actual: String? = null, val source: String? = null) {
    val best: String? get() = actual ?: planned
    val hasChanged: Boolean get() = planned != null && actual != null && planned != actual
}

@Serializable
data class CoupledTrain(val name: String, val direction: String? = null, val tripId: String? = null)

@Serializable
data class Line(
    val name: String,
    val number: String? = null,
    val product: String,
    val operatorName: String? = null,
    val alternateName: String? = null,
    val tripNumber: String? = null,
    val coupledTrains: List<CoupledTrain>? = null,
)

/** What the Kit computes for a line (`Android/kit/Bridge/Display.swift`). */
@Serializable
data class LineDisplay(
    val displayName: String,
    val nameWithTripNumber: String,
    val filterProduct: String,
    val isNightTrain: Boolean = false,
    /** 0xRRGGBB of the line's own colour (some S-/U-Bahn lines), else the product's. */
    val colorHex: Long? = null,
)

@Serializable
data class TrainMessage(val kind: String, val text: String, val timestamp: Long? = null)

@Serializable
data class Stopover(
    val station: Station,
    val arrival: TimeInfo? = null,
    val departure: TimeInfo? = null,
    val arrivalPlatform: PlatformInfo? = null,
    val departurePlatform: PlatformInfo? = null,
    val arrivalCancelled: Boolean = false,
    val departureCancelled: Boolean = false,
    /** normal, exitOnly, entryOnly, passThrough */
    val access: String = "normal",
    val isAdditional: Boolean = false,
    val isManual: Boolean = false,
) {
    val cancelled: Boolean
        get() = if (arrival == null && departure == null) arrivalCancelled && departureCancelled
        else (arrival == null || arrivalCancelled) && (departure == null || departureCancelled)
    val allowsBoarding: Boolean get() = access == "normal" || access == "entryOnly"
    val allowsAlighting: Boolean get() = access == "normal" || access == "exitOnly"
}

@Serializable
data class Leg(
    val origin: Station,
    val destination: Station,
    val departure: TimeInfo,
    val arrival: TimeInfo,
    val departurePlatform: PlatformInfo? = null,
    val arrivalPlatform: PlatformInfo? = null,
    val tripId: String? = null,
    val line: Line? = null,
    val direction: String? = null,
    val isWalking: Boolean = false,
    val cancelled: Boolean = false,
    val stopovers: List<Stopover> = emptyList(),
    val remarks: List<String> = emptyList(),
    val messages: List<TrainMessage> = emptyList(),
    val source: String,
)

@Serializable
data class Journey(val legs: List<Leg>, val source: String) {
    val departure: TimeInfo? get() = legs.firstOrNull()?.departure
    val arrival: TimeInfo? get() = legs.lastOrNull()?.arrival
    val origin: Station? get() = legs.firstOrNull()?.origin
    val destination: Station? get() = legs.lastOrNull()?.destination
    val transitLegs: List<Leg> get() = legs.filter { !it.isWalking }
}

@Serializable
data class LegDisplay(
    val line: LineDisplay? = null,
    val direction: String? = null,
    val intermediateStops: List<Stopover> = emptyList(),
    val hasDelayReason: Boolean = false,
    /** "Ausstieg in Fahrtrichtung links", if known. */
    val exitSide: String? = null,
)

@Serializable
data class Issue(val title: String, val message: String, val isBlocking: Boolean)

@Serializable
data class JourneyDisplay(
    val id: String,
    val journey: Journey,
    val legs: List<LegDisplay>,
    val transfers: Int,
    val durationSeconds: Double? = null,
    /** Per leg, start and end on the journey's bar (ms). */
    val barSpans: List<List<Long>> = emptyList(),
    val isCancelled: Boolean,
    val isOver: Boolean = false,
    val brokenTransferIndices: List<Int> = emptyList(),
    val issues: List<Issue> = emptyList(),
) {
    /** The journey's Kit JSON, to hand back (save, refresh, open a leg's train). */
    @Transient
    var raw: JsonObject = JsonObject(emptyMap())

    fun rawLeg(index: Int): JsonObject = raw.getValue("legs").jsonArray[index].jsonObject
}

@Serializable
data class JourneysPage(
    val journeys: List<JourneyDisplay>,
    val earlierCursor: String? = null,
    val laterCursor: String? = null,
)

@Serializable
data class BoardEntry(
    /** departures or arrivals */
    val kind: String,
    val tripId: String,
    val station: Station,
    val line: Line,
    /** Departures: where the train goes. Arrivals: where it comes from. */
    val otherEnd: String? = null,
    val time: TimeInfo,
    val platform: PlatformInfo = PlatformInfo(),
    val cancelled: Boolean = false,
    val remarks: List<String> = emptyList(),
    val access: String = "normal",
    val source: String,
)

@Serializable
data class BoardEntryDisplay(val id: String, val entry: BoardEntry, val line: LineDisplay)

@Serializable
data class Trip(
    val id: String,
    val line: Line? = null,
    val direction: String? = null,
    val stopovers: List<Stopover> = emptyList(),
    val cancelled: Boolean = false,
    val remarks: List<String> = emptyList(),
    val messages: List<TrainMessage> = emptyList(),
    val source: String,
) {
    val origin: Station? get() = stopovers.firstOrNull()?.station
    val destination: Station? get() = stopovers.lastOrNull()?.station
}

@Serializable
data class TripDisplay(val trip: Trip, val line: LineDisplay? = null) {
    /** The trip's Kit JSON, to build a ride from it. */
    @Transient
    var raw: JsonObject = JsonObject(emptyMap())
}

/** A run found by its number (`TrainSearchResult`); [raw] goes back to the Kit to open it. */
@Serializable
data class TrainResult(
    val journeyId: String,
    val name: String? = null,
    val lineName: String? = null,
    val product: String,
    val origin: String,
    val destination: String,
) {
    @Transient
    var raw: JsonObject = JsonObject(emptyMap())
}

/** A found run, opened: the entry as on a board, and the trip. */
data class TrainRun(val entry: BoardEntryDisplay, val trip: TripDisplay)

/** The Kit's product groups (`Product`), in the order the filter chips show them. */
@Serializable(with = ProductSerializer::class)
enum class Product(val id: String, val displayName: String, val isTrain: Boolean, val isLongDistance: Boolean) {
    HighSpeed("highSpeed", "Hochgeschwindigkeit", true, true),
    LongDistance("longDistance", "IC / EC", true, true),
    NightTrain("nightTrain", "Nachtzug", true, true),
    Interregio("interregio", "IR / FLX", true, true),
    RegionalExpress("regionalExpress", "RE", true, false),
    Regional("regional", "RB", true, false),
    Suburban("suburban", "S-Bahn", true, false),
    Subway("subway", "U-Bahn", false, false),
    Tram("tram", "Tram", false, false),
    Bus("bus", "Bus", false, false),
    Coach("coach", "Fernbus", false, false),
    Ferry("ferry", "Fähre", false, false),
    Other("other", "Sonstige", false, false);

    companion object {
        fun of(id: String): Product = entries.firstOrNull { it.id == id } ?: Other
        val all: Set<Product> = entries.toSet()
        val trains: Set<Product> = entries.filter { it.isTrain }.toSet()
        val longDistance: Set<Product> = entries.filter { it.isLongDistance }.toSet()
        /** The board's "Nur Regionalverkehr": RE and RB only. */
        val regional: Set<Product> = setOf(RegionalExpress, Regional)
    }
}

/** Products are stored by the Kit's raw values; an unknown one reads as [Product.Other], as in the Kit. */
object ProductSerializer : KSerializer<Product> {
    override val descriptor = PrimitiveSerialDescriptor("Product", PrimitiveKind.STRING)
    override fun deserialize(decoder: Decoder): Product = Product.of(decoder.decodeString())
    override fun serialize(encoder: Encoder, value: Product) = encoder.encodeString(value.id)
}
