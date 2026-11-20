package de.goldkunibert.betterbahn.kit

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.BeforeClass
import org.junit.Test

/**
 * The real bridge (`Android/kit/Bridge`) through JNI, built for Linux by `Android/kit/bridge-linux.sh`: JSON both
 * ways as UTF-8, the Kit finding its data, errors as [KitException]. Only methods that ask no server. Skipped
 * without `KIT_LINUX_DIR` (see `build.gradle.kts`).
 */
class KitBridgeTest {
    companion object {
        private val folder: String? = System.getProperty("betterbahn.kitLinuxDir")

        @BeforeClass
        @JvmStatic
        fun start() {
            if (folder != null) Kit.startForTests(folder)
        }
    }

    private fun call(method: String, arguments: JsonObject = JsonObject(emptyMap())) =
        Kit.callDirectly(method, arguments)

    /** Recorded journeys without the names the bridge added, so the Kit has to add them again. */
    private fun recordedJourneys() =
        KitJson.parseAnswer(javaClass.classLoader!!.getResource("kit/journeys.json")!!.readText())
            .jsonObject["journeys"]!!.jsonArray.map { withoutDisplayNames(it.jsonObject["journey"]!!) as JsonObject }

    private fun withoutDisplayNames(element: JsonElement): JsonElement = when (element) {
        is JsonObject -> JsonObject(element.filterKeys { it != "displayName" }.mapValues { withoutDisplayNames(it.value) })
        is JsonArray -> JsonArray(element.map(::withoutDisplayNames))
        else -> element
    }

    @Test
    fun describesSavedJourneysWithoutAServer() {
        assumeTrue(folder != null)
        val raws = recordedJourneys()
        val described = KitJson.json.decodeFromJsonElement(
            kotlinx.serialization.builtins.ListSerializer(JourneyDisplay.serializer()),
            call("describeJourneys", buildJsonObject { put("journeys", JsonArray(raws)) }),
        )
        assertEquals(raws.size, described.size)
        val first = described.first()
        assertEquals(first.journey.legs.size, first.legs.size)
        // Station names come from the Kit's data (StationNames.json), so the data folder was found; umlauts
        // survive the trip through JNI.
        assertEquals("Berlin Hbf", first.journey.legs.first { !it.isWalking }.destination.displayName)
        assertTrue(described.flatMap { it.journey.legs }.any { it.destination.displayName == "München Hbf" })
    }

    /** Where a saved journey stands: before its first train, on it, between trains, and nothing once arrived. */
    @Test
    fun liveStatusFollowsTheJourney() {
        assumeTrue(folder != null)
        val raw = recordedJourneys().first()
        val journey = KitJson.json.decodeFromJsonElement(Journey.serializer(), raw)
        val transit = journey.legs.indices.filter { !journey.legs[it].isWalking }
        fun status(now: Long) = call("liveStatus", buildJsonObject { put("journey", raw); put("now", now) })
            .let { if (it is kotlinx.serialization.json.JsonNull) null else KitJson.json.decodeFromJsonElement(LiveStatus.serializer(), it) }

        val first = journey.legs[transit.first()]
        val before = status(first.departure.best - 30 * 60_000)!!
        assertEquals("departure", before.step)
        assertEquals(transit.first(), before.legIndex)
        assertEquals(transit, before.upcomingIndices)

        val riding = status(first.departure.best + 60_000)!!
        assertEquals("riding", riding.step)
        if (transit.size > 1) {
            // From 10 minutes before the arrival the change after it shows.
            val soon = status(first.arrival.best - 5 * 60_000)!!
            assertEquals(transit[1], soon.nextTransfer?.nextIndex)
            val between = status(first.arrival.best + 30_000)
            if (between != null && journey.legs[transit[1]].departure.best > first.arrival.best + 30_000) {
                assertEquals("transfer", between.step)
                assertEquals(transit.first(), between.previousIndex)
            }
        }
        assertEquals(null, status(journey.legs.last().arrival.best + 60_000))
    }

    /** A result long over isn't checked live: nothing could change it. */
    @Test
    fun noLiveCheckForPastJourneys() {
        assumeTrue(folder != null)
        val answer = call("checkLive", buildJsonObject { put("journey", recordedJourneys().first()) })
        assertTrue(answer is kotlinx.serialization.json.JsonNull)
    }

    @Test
    fun keepsTheWorkerToken() {
        assumeTrue(folder != null)
        val expires = System.currentTimeMillis() + 3_600_000
        call("setWorkerToken", buildJsonObject { put("token", "test-token"); put("expiresAt", expires) })
        assertEquals("true", call("hasWorkerToken").jsonPrimitive.content)
        call("setWorkerToken", buildJsonObject { put("token", null as String?); put("expiresAt", expires) })
        assertEquals("false", call("hasWorkerToken").jsonPrimitive.content)
    }

    @Test(expected = KitException::class)
    fun unknownMethodFails() {
        assumeTrue(folder != null)
        call("noSuchMethod")
    }
}
