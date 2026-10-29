package de.goldkunibert.betterbahn.kit

import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Kotlin models against real answers of the bridge (recorded on Linux with the same Swift code). */
class KitJsonTest {
    private fun fixture(name: String): String =
        javaClass.classLoader!!.getResource("kit/$name.json")!!.readText()

    @Test
    fun stations() {
        val stations = KitJson.json.decodeFromJsonElement<List<Station>>(KitJson.parseAnswer(fixture("stations")))
        assertTrue(stations.any { it.shownName == "Hamburg Hbf" })
        // Stations go back to the Kit unchanged.
        val hbf = stations.first { it.shownName == "Hamburg Hbf" }
        val again = KitJson.json.decodeFromJsonElement<Station>(KitJson.json.encodeToJsonElement(hbf))
        assertEquals(hbf, again)
    }

    @Test
    fun journeys() {
        val page = KitJson.journeysPage(KitJson.parseAnswer(fixture("journeys")))
        assertTrue(page.journeys.isNotEmpty())
        assertNotNull(page.laterCursor)
        val first = page.journeys.first()
        assertEquals(first.journey.legs.size, first.legs.size)
        assertEquals(first.journey.legs.size, first.barSpans.size)
        assertNotNull(first.durationSeconds)
        assertTrue(first.raw.containsKey("legs"))
        assertTrue(first.rawLeg(0).containsKey("origin"))
        val transit = first.journey.legs.indices.first { !first.journey.legs[it].isWalking }
        assertNotNull(first.legs[transit].line)
        assertNotNull(first.journey.legs[transit].origin.displayName)
    }

    @Test
    fun board() {
        val entries = KitJson.json.decodeFromJsonElement<List<BoardEntryDisplay>>(KitJson.parseAnswer(fixture("board")))
        assertTrue(entries.isNotEmpty())
        assertTrue(entries.all { it.line.displayName.isNotEmpty() })
        assertEquals(entries.map { it.entry.time.best }.sorted(), entries.map { it.entry.time.best })
    }

    @Test
    fun trip() {
        val trip = KitJson.trip(KitJson.parseAnswer(fixture("trip")))
        assertTrue(trip.trip.stopovers.size > 2)
        assertTrue(trip.raw.containsKey("stopovers"))
        assertFalse(trip.trip.stopovers.first().station.shownName.isEmpty())
    }

    @Test
    fun trains() {
        val trains = KitJson.trains(KitJson.parseAnswer(fixture("trains")))
        assertEquals("ICE 585", trains.first().name)
        // Goes back to the Kit as it came.
        assertTrue(trains.first().raw.containsKey("journeyId") && trains.first().raw.containsKey("category"))
    }

    @Test(expected = KitException::class)
    fun error() {
        KitJson.parseAnswer("""{"error":"Keine Verbindung"}""")
    }

    @Test
    fun timeInfo() {
        val time = TimeInfo(planned = 0, actual = 4 * 60_000 + 40_000)
        assertEquals(5, time.delayMinutes)
        assertEquals("""{"planned":1.5}""".let { KitJson.json.decodeFromString<TimeInfo>(it).planned }, 1L)
    }
}
