package timetagger

import timetagger.config.Config
import timetagger.db.Database
import timetagger.model.Tags
import kotlin.test.Test
import kotlin.test.assertEquals

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
        assertEquals(listOf("call", "core-2517"), Tags.of("#call CORE #Core-2517, #call"))
        assertEquals(emptyList(), Tags.of("no tags # here"))
    }
}
