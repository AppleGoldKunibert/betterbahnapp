package de.goldkunibert.betterbahn.kit

import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
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

    @Test
    fun coaches() {
        val sequence = KitJson.json.decodeFromJsonElement<CoachSequence>(KitJson.parseAnswer(fixture("coaches")))
        assertEquals(13, sequence.coaches.size)
        assertTrue(sequence.coaches.any { it.kind == "halfDiningCar" })
        assertTrue(sequence.coaches.first().amenities.contains("BIKE_SPACE"))
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

    /** A train candidate keeps its requirement to hand back; the live status reads as the bridge writes it. */
    @Test
    fun trainCandidatesAndLiveStatus() {
        val answer = """{"ok":[{"id":"t|3","name":"ICE 91","isExact":true,"requirement":{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","trainName":"ICE 91"}},
            {"id":"u|-1","name":"RE 3","isExact":false}]}"""
        val candidates = KitJson.trainCandidates(KitJson.parseAnswer(answer))
        assertEquals(2, candidates.size)
        assertEquals("ICE 91", candidates[0].requirement?.get("trainName")?.jsonPrimitive?.content)
        assertEquals(null, candidates[1].requirement)

        val status = KitJson.json.decodeFromJsonElement<LiveStatus>(KitJson.parseAnswer(
            """{"ok":{"step":"riding","legIndex":1,"nextTransfer":{"nextIndex":3,"minutes":7,"waiting":false,"isMissed":false},"upcomingIndices":[1,3]}}""",
        ))
        assertEquals("riding", status.step)
        assertEquals(7, status.nextTransfer?.minutes)
        assertEquals(listOf(1, 3), status.upcomingIndices)
    }
}
