package timetagger

import timetagger.config.Config
import timetagger.db.Database
import timetagger.model.Record
import timetagger.model.Tags
import timetagger.routes.watchToday
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class UnitTest {
    @Test
    fun configFromEnvAndArgs() {
        val c = Config.load(listOf("--bind=0.0.0.0:80", "--path-prefix", "tt"), mapOf("TIMETAGGER_BIND" to "1.2.3.4:9"))
        assertEquals("0.0.0.0", c.host)
        assertEquals(80, c.port)
        assertEquals("/tt/", c.pathPrefix)
        assertEquals("/", Config.toPathPrefix("/"))
    }

    @Test
    fun dbUri() {
        val c = Database.jdbcConfig("postgresql://u%40x:p%3Aw@db:5433/tt?sslmode=disable")
        assertEquals("jdbc:postgresql://db:5433/tt?sslmode=disable", c.jdbcUrl)
        assertEquals("u@x", c.username)
        assertEquals("p:w", c.password)
    }

    @Test
    fun tags() {
        assertEquals(listOf("call", "core-2517"), Tags.normalize(listOf("#call", " Core-2517", "call", "")))
        assertNull(Tags.normalize(listOf("two words")))
        assertNull(Tags.normalize(listOf("a,b")))
    }

    @Test
    fun watchTodayCountsRecordsByStartDay() {
        fun rec(start: String, stop: String?) = Record(1, Instant.parse(start), stop?.let(Instant::parse), "w", null, emptyList(), null, 1)
        val zone = ZoneId.of("Europe/Podgorica") // UTC+1 in November
        val now = Instant.parse("2026-11-15T10:30:00Z")
        val w = watchToday(
            listOf(
                rec("2026-11-14T22:30:00Z", "2026-11-14T23:30:00Z"), // started on the 14th locally: left out
                rec("2026-11-15T07:00:00Z", "2026-11-15T09:00:00Z"),
                rec("2026-11-15T10:00:00Z", null), // running: counts until now
            ),
            LocalDate.of(2026, 11, 15), zone, 460, now,
        )
        assertEquals(9000, w.trackedSeconds)
        assertEquals("2:30", w.line1)
        assertEquals("/ 7:40 ●", w.line2)
        assertEquals(true, w.running)
    }
}
