package timetagger

import timetagger.auth.AuthException
import timetagger.auth.AuthInfo
import timetagger.auth.IpRanges
import timetagger.auth.JwtCodec
import timetagger.config.Config
import timetagger.db.Database
import timetagger.model.InvalidItem
import timetagger.model.ItemParser
import timetagger.model.Record

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class UnitTest {
    @Test
    fun configFromEnvAndArgs() {
        val c = Config.load(
            listOf("--bind=0.0.0.0:80", "--path-prefix", "tt"),
            mapOf("TIMETAGGER_BIND" to "1.2.3.4:9", "TIMETAGGER_PROXY_AUTH_ENABLED" to "yes"),
        )
        assertEquals("0.0.0.0", c.host)
        assertEquals(80, c.port)
        assertEquals("/tt/", c.pathPrefix)
        assertTrue(c.proxyAuthEnabled)
        assertEquals("/", Config.toPathPrefix("/"))
    }

    @Test
    fun ipRanges() {
        val r = IpRanges("127.0.0.1, 10.99.0.0/24;192.168/16")
        assertTrue(r.contains("127.0.0.1"))
        assertTrue(r.contains("10.99.0.200"))
        assertFalse(r.contains("10.99.1.1"))
        assertTrue(r.contains("192.168.44.1"))
        assertFalse(r.contains("192.169.0.1"))
    }

    @Test
    fun readsTokensFromThePythonServer() {
        // Made with pyjwt: jwt.encode({...}, "testkey", algorithm="HS256").
        val python = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJ1c2VybmFtZSI6ImFsaWNlIiwiZXhwaXJlcyI6MzI1MDM3NDg0MDAsInNlZWQiOiJhYmMifQ." +
            "AAIu7o6jPLyF2RWVd1pk4FqZKiV9LoMt22pxPCPomLc"
        val tokens = JwtCodec("testkey")
        assertEquals(AuthInfo("alice", 32503748400, "abc"), tokens.decode(python))
        assertEquals(AuthInfo("bob", 1, "x"), tokens.decode(tokens.encode(AuthInfo("bob", 1, "x"))))
        assertFailsWith<AuthException> { JwtCodec("otherkey").decode(python) }
    }

    @Test
    fun recordValidation() {
        fun parse(s: String) = ItemParser.record(Json.parseToJsonElement(s).jsonObject)
        assertEquals(Record("a", 5, 1, 2, "", 0), parse("""{"key":"a","mt":5.0,"t1":"1","t2":2,"extra":1}"""))
        assertFailsWith<InvalidItem> { parse("""{"key":"a","mt":5.5,"t1":1,"t2":2}""") }
        assertFailsWith<InvalidItem> { parse("""{"key":"a","t1":1,"t2":2}""") }
        assertFailsWith<InvalidItem> { parse("""{"key":"a","mt":1,"t1":1,"t2":2,"ds":"${"x".repeat(256)}"}""") }
    }

    @Test
    fun dbUri() {
        val c = Database.jdbcConfig("postgresql://u%40x:p%3Aw@db:5433/tt?sslmode=disable")
        assertEquals("jdbc:postgresql://db:5433/tt?sslmode=disable", c.jdbcUrl)
        assertEquals("u@x", c.username)
        assertEquals("p:w", c.password)
    }
}
