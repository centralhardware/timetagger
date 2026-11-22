package timetagger.db

import kotlinx.coroutines.future.await
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.time.Duration
import java.util.Base64

/**
 * A minimal client for ClickHouse's HTTP interface, from a URI like
 * http://user:pass@host:8123/database. Values go in as query parameters ({name:Type}), never spliced into SQL.
 */
class ClickHouse(uri: String) {
    private val base: String
    private val database: String
    private val authHeader: String?
    private val http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build()

    init {
        val u = URI(uri.trim())
        base = "${u.scheme}://${u.host}:${if (u.port > 0) u.port else 8123}/"
        database = u.path.trim('/').ifEmpty { "default" }
        authHeader = u.rawUserInfo?.let { info ->
            val user = URLDecoder.decode(info.substringBefore(":"), Charsets.UTF_8)
            val pass = if (":" in info) URLDecoder.decode(info.substringAfter(":"), Charsets.UTF_8) else ""
            "Basic " + Base64.getEncoder().encodeToString("$user:$pass".toByteArray())
        }
    }

    private fun request(sql: String, params: Map<String, Any>, body: String?): HttpRequest {
        val query = (mapOf("database" to database, "query" to sql) + params.mapKeys { "param_${it.key}" })
            .entries.joinToString("&") { (k, v) -> "$k=" + URLEncoder.encode(v.toString(), Charsets.UTF_8) }
        val b = HttpRequest.newBuilder(URI("$base?$query")).timeout(Duration.ofSeconds(30))
        authHeader?.let { b.header("Authorization", it) }
        return b.POST(HttpRequest.BodyPublishers.ofString(body.orEmpty())).build()
    }

    private suspend fun send(sql: String, params: Map<String, Any> = emptyMap(), body: String? = null): String {
        val resp = http.sendAsync(request(sql, params, body), HttpResponse.BodyHandlers.ofString()).await()
        if (resp.statusCode() !in 200..299) error("ClickHouse ${resp.statusCode()}: ${resp.body().take(500)}")
        return resp.body()
    }

    suspend fun execute(sql: String) { send(sql) }

    /** Inserts rows, one JSON object each. */
    suspend fun insert(table: String, rows: List<JsonObject>) {
        if (rows.isEmpty()) return
        send("INSERT INTO $table FORMAT JSONEachRow", body = rows.joinToString("\n"))
    }

    /** The rows of a SELECT as JSON objects. */
    suspend fun select(sql: String, params: Map<String, Any> = emptyMap()): List<JsonObject> =
        Json.parseToJsonElement(send("$sql FORMAT JSON", params)).jsonObject["data"]!!.jsonArray.map { it.jsonObject }
}
