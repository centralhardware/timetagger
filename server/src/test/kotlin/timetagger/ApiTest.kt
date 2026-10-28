package timetagger

import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.put
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.http.HttpStatusCode
import io.ktor.server.testing.ApplicationTestBuilder
import io.ktor.server.testing.testApplication
import io.zonky.test.db.postgres.embedded.EmbeddedPostgres
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import java.util.Base64
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class ApiTest {
    private lateinit var pg: EmbeddedPostgres
    private lateinit var db: Db
    private val config = Config(jwtKey = "test-key")

    @BeforeTest
    fun setUp() {
        pg = EmbeddedPostgres.start()
        db = Db("postgresql://postgres:postgres@localhost:${pg.port}/postgres")
        runBlocking {
            db.migrate()
            db.migrate() // idempotent
            Credentials(db).set("alice", "secret")
        }
    }

    @AfterTest
    fun tearDown() {
        db.close()
        pg.close()
    }

    private fun api(block: suspend ApplicationTestBuilder.() -> Unit) = testApplication {
        application { module(config, db) }
        block()
    }

    private suspend fun ApplicationTestBuilder.login(user: String = "alice", pw: String = "secret"): HttpResponse {
        val body = """{"method":"usernamepassword","username":"$user","password":"$pw"}"""
        return client.post("/timetagger/api/v2/bootstrap_authentication") {
            setBody(Base64.getEncoder().encodeToString(body.toByteArray()))
        }
    }

    private fun json(s: String) = Json.parseToJsonElement(s).jsonObject
    private suspend fun HttpResponse.obj(): JsonObject = json(bodyAsText())

    @Test
    fun loginAndTokens() = api {
        assertEquals(HttpStatusCode.Forbidden, login(pw = "wrong").status)
        val web = login().obj()["token"]!!.jsonPrimitive.content
        val apiToken = client.get("/timetagger/api/v2/apitoken") { header("authtoken", web) }.obj()["token"]!!.jsonPrimitive.content
        assertEquals(HttpStatusCode.OK, client.get("/timetagger/api/v2/version") { header("authtoken", apiToken) }.status)
        // An API token cannot mint more tokens.
        assertEquals(HttpStatusCode.Forbidden, client.get("/timetagger/api/v2/webtoken") { header("authtoken", apiToken) }.status)
        // Resetting the seed revokes earlier API tokens.
        client.get("/timetagger/api/v2/apitoken?reset=1") { header("authtoken", web) }
        val revoked = client.get("/timetagger/api/v2/version") { header("authtoken", apiToken) }
        assertEquals(HttpStatusCode.Unauthorized, revoked.status)
        assertTrue("revoked" in revoked.bodyAsText())
        assertEquals(HttpStatusCode.Unauthorized, client.get("/timetagger/api/v2/version").status)
        assertEquals("ok", client.get("/timetagger/status").bodyAsText())
        assertEquals(HttpStatusCode.NotFound, client.get("/timetagger/api/v2/nope") { header("authtoken", web) }.status)
        assertEquals(HttpStatusCode.MethodNotAllowed, client.put("/timetagger/api/v2/version") { header("authtoken", web) }.status)
    }

    @Test
    fun recordsAndUpdates() = api {
        val token = login().obj()["token"]!!.jsonPrimitive.content
        suspend fun put(body: String) = client.put("/timetagger/api/v2/records") { header("authtoken", token); setBody(body) }.obj()
        suspend fun get(q: String) = client.get("/timetagger/api/v2/records?$q") { header("authtoken", token) }.obj()["records"]!!.jsonArray

        val r = put(
            """[{"key":"a","mt":10,"t1":100,"t2":200,"ds":"code #work"},
                {"key":"b","mt":10,"t1":300,"t2":300,"ds":"run #work #x"},
                {"key":"c","mt":10,"t1":400,"t2":500,"ds":"gone","deleted":1},
                {"key":"bad","mt":10},
                {"nokey":1}]""",
        )
        assertEquals(listOf("a", "b", "c"), r["accepted"]!!.jsonArray.map { it.jsonPrimitive.content })
        assertEquals(listOf("bad"), r["failed"]!!.jsonArray.map { it.jsonPrimitive.content })
        assertEquals(2, r["errors"]!!.jsonArray.size)

        assertEquals(setOf("a", "b", "c"), get("timerange=0-1000").map { it.jsonObject["key"]!!.jsonPrimitive.content }.toSet())
        assertEquals(listOf("b"), get("timerange=0-1000&running=1").map { it.jsonObject["key"]!!.jsonPrimitive.content })
        assertEquals(listOf("c"), get("timerange=0-1000&hidden=yes").map { it.jsonObject["key"]!!.jsonPrimitive.content })
        assertEquals(listOf("b"), get("timerange=0-1000&tag=x").map { it.jsonObject["key"]!!.jsonPrimitive.content })
        assertEquals(2, get("timerange=0-1000&tag=%23work").size)
        // A running record shows up for any later range.
        assertEquals(listOf("b"), get("timerange=600-700").map { it.jsonObject["key"]!!.jsonPrimitive.content })

        // Older edits lose; newer ones win.
        put("""[{"key":"a","mt":5,"t1":1,"t2":2,"ds":"old"}]""")
        put("""[{"key":"b","mt":20,"t1":300,"t2":350,"ds":"run #work"}]""")
        val byKey = get("timerange=0-1000").associate { it.jsonObject["key"]!!.jsonPrimitive.content to it.jsonObject }
        assertEquals("code #work", byKey["a"]!!["ds"]!!.jsonPrimitive.content)
        assertEquals(350, byKey["b"]!!["t2"]!!.jsonPrimitive.long)

        val all = client.get("/timetagger/api/v2/updates?since=0") { header("authtoken", token) }.obj()
        assertEquals(3, all["records"]!!.jsonArray.size)
        val serverTime = all["server_time"]!!.jsonPrimitive.content.toDouble()
        val none = client.get("/timetagger/api/v2/updates?since=${serverTime + 1}") { header("authtoken", token) }.obj()
        assertEquals(0, none["reset"]!!.jsonPrimitive.int)

        client.put("/timetagger/api/v2/forcereset") { header("authtoken", token) }
        val reset = client.get("/timetagger/api/v2/updates?since=1") { header("authtoken", token) }.obj()
        assertEquals("true", reset["reset"]!!.jsonPrimitive.content)
        assertEquals(3, reset["records"]!!.jsonArray.size)
    }

    @Test
    fun settings() = api {
        val token = login().obj()["token"]!!.jsonPrimitive.content
        client.put("/timetagger/api/v2/settings") {
            header("authtoken", token)
            setBody("""[{"key":"tag_colors","mt":1,"value":{"work":"#f00"}}]""")
        }
        val s = client.get("/timetagger/api/v2/settings") { header("authtoken", token) }.obj()["settings"]!!.jsonArray
        assertEquals("#f00", s.single().jsonObject["value"]!!.jsonObject["work"]!!.jsonPrimitive.content)
    }

    @Test
    fun verifiesPasswordsHashedByThePythonServer() = runBlocking {
        db.io { conn ->
            conn.createStatement().use {
                it.execute(
                    "INSERT INTO credentials (username, pw_hash, modified_time) VALUES " +
                        "('py', '\$2b\$12\$6wamkYM992RYyml95emmjeW8uFNBxiNV5xrHemIjuZJdVyOM6j0Zm', 0)",
                )
            }
        }
        assertTrue(Credentials(db).verify("py", "secret"))
    }
}
