package de.goldkunibert.betterbahn.kit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class PlayIntegrityTest {
    /** The same hash the Worker computes (`sha256Hex` in Cloudflare/shared/playintegrity.mjs). */
    @Test fun requestHashMatchesTheWorker() {
        assertEquals(
            "5b5a0cada4c7a98f801522ddf290a735897fd59fc1340441dbfdeeb16545e071",
            PlayIntegrity.sha256Hex("eyJ0IjoiYyJ9.abc"),
        )
    }

    @Test fun offWithoutCloudProject() {
        assertFalse(PlayIntegrity.isActive)
    }
}
