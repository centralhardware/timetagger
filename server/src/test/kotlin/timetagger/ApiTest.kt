package timetagger

import io.ktor.client.request.delete
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.put
import io.ktor.client.request.request
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.http.contentType
import io.ktor.server.testing.ApplicationTestBuilder
import io.ktor.server.testing.testApplication
import io.zonky.test.db.postgres.embedded.EmbeddedPostgres
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.flywaydb.core.Flyway
import timetagger.auth.PasswordService
import timetagger.config.Config
import timetagger.db.Database
import timetagger.db.UserRepository
import java.util.Base64
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

private const val API = "/timetagger/api/v1"

class ApiTest {
    private lateinit var pg: EmbeddedPostgres
    private lateinit var db: Database

    @BeforeTest
    fun setUp() {
        pg = EmbeddedPostgres.start()
        db = Database("postgresql://postgres:postgres@localhost:${pg.port}/postgres")
        db.migrate()
        runBlocking { PasswordService(db, UserRepository()).set("alice", "secret") }
    }

    @AfterTest
    fun tearDown() {
        db.close()
        pg.close()
    }

    private fun api(block: suspend ApplicationTestBuilder.() -> Unit) = testApplication {
        application { module(Config(jwtKey = "test-key"), db) }
        block()
    }

    private suspend fun ApplicationTestBuilder.login(user: String = "alice", pw: String = "secret") =
        client.post("$API/sessions") { header("Authorization", "Basic " + Base64.getEncoder().encodeToString("$user:$pw".toByteArray())) }

    private suspend fun ApplicationTestBuilder.token() = login().obj()["token"]!!.jsonPrimitive.content

    private suspend fun HttpResponse.obj(): JsonObject = Json.parseToJsonElement(bodyAsText()).jsonObject

    @Test
    fun sessionsAndTokens() = api {
        assertEquals(HttpStatusCode.Unauthorized, login(pw = "wrong").status)
        val web = token()
        val apiToken = client.post("$API/tokens") { header("Authorization", "Bearer $web") }.obj()["token"]!!.jsonPrimitive.content
        assertEquals("alice", client.get("$API/me") { header("Authorization", "Bearer $apiToken") }.obj()["username"]!!.jsonPrimitive.content)
        // An API token cannot mint more tokens.
        assertEquals(HttpStatusCode.Forbidden, client.post("$API/tokens") { header("Authorization", "Bearer $apiToken") }.status)
        // Revoking API tokens leaves web tokens working.
        assertEquals(HttpStatusCode.NoContent, client.delete("$API/tokens/api") { header("Authorization", "Bearer $web") }.status)
        val revoked = client.get("$API/me") { header("Authorization", "Bearer $apiToken") }
        assertEquals(HttpStatusCode.Unauthorized, revoked.status)
        assertEquals("unauthorized", revoked.obj()["error"]!!.jsonPrimitive.content)
        assertEquals(HttpStatusCode.OK, client.get("$API/me") { header("Authorization", "Bearer $web") }.status)
        assertEquals(HttpStatusCode.OK, client.get("$API/version").status)
        assertEquals("ok", client.get("/timetagger/status").bodyAsText())
        assertEquals("not_found", client.get("$API/nope") { header("Authorization", "Bearer $web") }.obj()["error"]!!.jsonPrimitive.content)
    }

    @Test
    fun records() = api {
        val t = token()
        suspend fun send(method: String, path: String, body: String) = client.request("$API/$path") {
            this.method = HttpMethod.parse(method)
            header("Authorization", "Bearer $t"); contentType(ContentType.Application.Json); setBody(body)
        }
        suspend fun create(body: String): Long {
            val r = send("POST", "records", body)
            assertEquals(HttpStatusCode.Created, r.status, r.bodyAsText())
            return r.obj()["id"]!!.jsonPrimitive.long.also { assertEquals("$API/records/$it", r.headers["Location"]) }
        }
        suspend fun list(q: String) = client.get("$API/records?$q") { header("Authorization", "Bearer $t") }
            .obj()["records"]!!.jsonArray.map { it.jsonObject["id"]!!.jsonPrimitive.long }

        val a = create("""{"start":"2026-10-28T08:00:00Z","stop":"2026-10-28T09:00:00Z","description":"code #Work","modifiedAt":"2026-10-28T09:00:00Z"}""")
        assertEquals(listOf("work"), client.get("$API/records/$a") { header("Authorization", "Bearer $t") }.obj()["tags"]!!.jsonArray.map { it.jsonPrimitive.content })
        val b = create("""{"start":"2026-10-28T10:00:00Z","description":"run #work #x"}""")
        assertEquals(b, a + 1)
        assertEquals(HttpStatusCode.UnprocessableEntity, send("POST", "records", """{"start":"2026-10-28T10:00:00Z","stop":"2026-10-28T09:00:00Z"}""").status)
        assertEquals(HttpStatusCode.UnprocessableEntity, send("POST", "records", """{"stop":"nope"}""").status)
        assertEquals(HttpStatusCode.NotFound, send("PUT", "records/999", """{"start":"2026-10-28T10:00:00Z"}""").status)
        assertEquals(HttpStatusCode.NotFound, client.get("$API/records/abc") { header("Authorization", "Bearer $t") }.status)

        val day = "from=2026-10-28T00:00:00Z&to=2026-10-29T00:00:00Z"
        assertEquals(listOf(a, b), list(day))
        assertEquals(listOf(b), list("$day&running=true"))
        assertEquals(listOf(b), list("$day&tag=x&tag=work"))
        // A running record overlaps any later range.
        assertEquals(listOf(b), list("from=2026-11-01T00:00:00Z&to=2026-11-02T00:00:00Z"))
        assertEquals(HttpStatusCode.UnprocessableEntity, client.get("$API/records?from=yesterday&to=now") { header("Authorization", "Bearer $t") }.status)

        // An older edit is refused with the current record.
        val stale = send("PUT", "records/$a", """{"start":"2026-10-28T08:00:00Z","description":"old","modifiedAt":"2026-10-27T00:00:00Z"}""")
        assertEquals(HttpStatusCode.Conflict, stale.status)
        assertEquals("code #Work", stale.obj()["current"]!!.jsonObject["description"]!!.jsonPrimitive.content)

        // Stop b and start a new one in one go; one bad entry rejects the whole batch.
        val batch = send("POST", "records/batch", """{"records":[{"id":$b,"start":"2026-10-28T10:00:00Z","stop":"2026-10-28T11:00:00Z","description":"run #work"},
            {"start":"2026-10-28T11:00:00Z","description":"next"}]}""").obj()["records"]!!.jsonArray
        val c = batch[1].jsonObject["id"]!!.jsonPrimitive.long
        val badBatch = send("POST", "records/batch", """{"records":[{"start":"2026-10-28T12:00:00Z","description":"lost"},{"id":999,"start":"2026-10-28T12:00:00Z"}]}""")
        assertEquals(HttpStatusCode.NotFound, badBatch.status)
        assertEquals(listOf(a, b, c), list(day))
        assertEquals(listOf(c), list("$day&running=true"))

        assertEquals(HttpStatusCode.NoContent, client.delete("$API/records/$a") { header("Authorization", "Bearer $t") }.status)
        assertEquals(listOf(b, c), list(day))
        assertEquals(listOf(a), list("$day&deleted=true"))
        assertEquals(HttpStatusCode.NotFound, client.delete("$API/records/12345") { header("Authorization", "Bearer $t") }.status)

        // Sync: everything after a revision, deletes included.
        val all = client.get("$API/changes") { header("Authorization", "Bearer $t") }.obj()
        val rev = all["revision"]!!.jsonPrimitive.long
        assertEquals(3, all["records"]!!.jsonArray.size)
        send("PUT", "records/$c", """{"start":"2026-10-28T11:00:00Z","stop":"2026-10-28T11:30:00Z","description":"next"}""")
        val after = client.get("$API/changes?since=$rev") { header("Authorization", "Bearer $t") }.obj()
        assertEquals(listOf(c), after["records"]!!.jsonArray.map { it.jsonObject["id"]!!.jsonPrimitive.long })
    }

    @Test
    fun settings() = api {
        val t = token()
        val r = client.put("$API/settings/workdays") {
            header("Authorization", "Bearer $t"); contentType(ContentType.Application.Json); setBody("""{"value":2}""")
        }
        assertEquals(HttpStatusCode.OK, r.status)
        val s = client.get("$API/settings") { header("Authorization", "Bearer $t") }.obj()["settings"]!!.jsonArray
        assertEquals("2", s.single().jsonObject["value"]!!.jsonPrimitive.content)
        assertEquals(HttpStatusCode.NotFound, client.get("$API/settings/none") { header("Authorization", "Bearer $t") }.status)
    }
}

/** V5 converts a database written by the v2 server. */
class V5MigrationTest {
    @Test
    fun convertsV2Data() {
        EmbeddedPostgres.start().use { pg ->
            val flyway = Flyway.configure().dataSource(pg.postgresDatabase).locations("classpath:db/migration")
            flyway.target("4").load().migrate()
            pg.postgresDatabase.connection.use { c ->
                c.createStatement().use { st ->
                    st.execute("INSERT INTO credentials (username, pw_hash) VALUES ('alex', 'hash')")
                    st.execute(
                        """
                        INSERT INTO records ("user", "key", modified_time, start_time, stop_time, description, deleted, server_time) VALUES
                          ('alex', 'done', 100, 1000, 2000, '#Work code #call', 0, 5.5),
                          ('alex', 'run', 101, 3000, 3000, 'running', 0, 6.5),
                          ('alex', 'gone', 102, 500, 600, 'x', 1, 4.5)
                        """,
                    )
                    st.execute("""INSERT INTO settings ("user", "key", modified_time, value, server_time) VALUES ('alex', 'workdays', 1, '2', 1)""")
                    st.execute("""INSERT INTO userinfo ("user", "key", modified_time, value, server_time) VALUES ('alex', 'apitoken_seed', 1, '"seed1"', 1)""")
                }
            }
            flyway.target("latest").load().migrate()
            pg.postgresDatabase.connection.use { c ->
                c.createStatement().use { st ->
                    fun one(sql: String) = st.executeQuery(sql).let { it.next(); it.getString(1) }
                    assertEquals("hash", one("SELECT password_hash FROM users WHERE username = 'alex'"))
                    assertEquals("seed1", one("SELECT api_token_seed FROM users"))
                    assertNull(one("SELECT stop_at FROM records WHERE description = 'running'"))
                    assertEquals("1", one("SELECT count(*) FROM records WHERE deleted_at IS NOT NULL"))
                    assertEquals("call,work", one("SELECT string_agg(tag, ',' ORDER BY tag) FROM record_tags"))
                    // Revisions follow the old server-time order.
                    assertEquals("x,#Work code #call,running", one("SELECT string_agg(description, ',' ORDER BY revision) FROM records"))
                    assertEquals("1,2,3", one("SELECT string_agg(id::text, ',' ORDER BY id) FROM records"))
                    assertEquals("2", one("SELECT value::text FROM settings"))
                    assertEquals("0", one("SELECT count(*) FROM pg_tables WHERE tablename IN ('credentials', 'userinfo', 'schema_migrations')"))
                }
            }
        }
    }
}
