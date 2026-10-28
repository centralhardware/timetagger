package timetagger

import io.ktor.http.ContentType
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.server.application.ApplicationCall
import io.ktor.server.plugins.origin
import io.ktor.server.request.receiveText
import io.ktor.server.response.respondText
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.util.Base64

// Limits: values must be *shorter* than these.
const val STR_MAX = 256
const val JSON_MAX = 8192
private const val BODY_MAX = 10 * 1024 * 1024
private val FALSY = setOf("false", "off", "no", "n", "0")

class HttpError(val status: HttpStatusCode, message: String) : Exception(message)

/** The TimeTagger v2 API, served at `<prefix>api/v2/<path>`. */
class Api(private val config: Config, private val db: Db, private val tokens: Tokens, private val credentials: Credentials) {
    private val trustedProxies = IpRanges(config.proxyAuthTrusted)

    suspend fun handle(call: ApplicationCall, path: String) {
        try {
            when {
                path.isEmpty() && call.request.local.method == HttpMethod.Get ->
                    call.respondText("TimeTagger API v2")
                path == "bootstrap_authentication" -> call.json(bootstrap(call))
                else -> {
                    val auth = try {
                        tokens.authenticate(db, call.request.headers["authtoken"].orEmpty()).also {
                            if (config.proxyAuthEnabled) {
                                val proxyUser = proxyUser(call)
                                if (proxyUser.isNotEmpty() && proxyUser != it.username) {
                                    throw AuthException("Autheticated user does not match proxy user")
                                }
                            }
                        }
                    } catch (e: AuthException) {
                        throw HttpError(HttpStatusCode.Unauthorized, "unauthorized: ${e.message}")
                    }
                    call.json(route(call, path, auth, UserDb(db, auth.username)))
                }
            }
        } catch (e: HttpError) {
            call.respondText(e.message.orEmpty(), status = e.status)
        }
    }

    private suspend fun route(call: ApplicationCall, path: String, auth: AuthInfo, udb: UserDb): JsonElement {
        val method = call.request.local.method
        fun only(vararg allowed: HttpMethod) {
            if (method !in allowed) {
                val names = allowed.joinToString(" and ") { it.value }
                throw HttpError(HttpStatusCode.MethodNotAllowed, "method not allowed: /$path can only be used with $names")
            }
        }
        return when (path) {
            "version" -> { only(HttpMethod.Get); buildJsonObject { put("version", version()) } }
            "updates" -> { only(HttpMethod.Get); updates(call, udb) }
            "records" -> {
                only(HttpMethod.Get, HttpMethod.Put)
                if (method == HttpMethod.Get) getRecords(call, udb) else push(call, udb, "records")
            }
            "settings" -> {
                only(HttpMethod.Get, HttpMethod.Put)
                if (method == HttpMethod.Get) buildJsonObject { put("settings", JsonArray(udb.settings().map { it.json() })) }
                else push(call, udb, "settings")
            }
            "forcereset" -> {
                only(HttpMethod.Put)
                udb.tx { conn -> udb.putUserInfo(conn, "reset_time", JsonPrimitive(now())) }
                buildJsonObject { put("status", "ok") }
            }
            "webtoken", "apitoken" -> {
                only(HttpMethod.Get)
                if (auth.expires > now() + WEBTOKEN_LIFETIME) {
                    throw HttpError(HttpStatusCode.Forbidden, "forbidden: /$path needs auth with a web-token")
                }
                val reset = call.request.queryParameters["reset"].orEmpty().lowercase().let { it.isNotEmpty() && it !in FALSY }
                buildJsonObject { put("token", tokens.issue(udb, path, reset)) }
            }
            else -> throw HttpError(HttpStatusCode.NotFound, "not found: /$path is not a valid API path")
        }
    }

    // %% Auth bootstrap

    private suspend fun bootstrap(call: ApplicationCall): JsonElement {
        val body = runCatching {
            Json.parseToJsonElement(String(Base64.getDecoder().decode(call.receiveText().trim()))) as JsonObject
        }.getOrElse { throw HttpError(HttpStatusCode.BadRequest, "bad request: invalid authentication payload") }
        fun str(name: String) = (body[name] as? JsonPrimitive)?.contentOrNull.orEmpty()
        val user = when (val method = str("method").ifEmpty { "unspecified" }) {
            "usernamepassword" -> {
                val user = str("username").trim()
                if (!credentials.verify(user, str("password").trim())) {
                    throw HttpError(HttpStatusCode.Forbidden, "Invalid credentials")
                }
                user
            }
            "localhost" -> {
                if (!config.bind.startsWith("127.0.0.1")) {
                    throw HttpError(
                        HttpStatusCode.Forbidden,
                        "Can only login via localhost if the server address (config.bind) is '127.0.0.1'",
                    )
                }
                if (config.proxyAuthEnabled) throw HttpError(HttpStatusCode.Forbidden, "forbidden: disabled when proxy auth is available")
                if (call.request.local.serverHost !in setOf("localhost", "127.0.0.1")) {
                    throw HttpError(HttpStatusCode.Forbidden, "forbidden: must be on localhost")
                }
                "defaultuser"
            }
            "proxy" -> {
                if (!config.proxyAuthEnabled) throw HttpError(HttpStatusCode.Forbidden, "forbidden: proxy auth is not enabled")
                if (!trustedProxies.contains(call.request.origin.remoteAddress)) {
                    throw HttpError(HttpStatusCode.Forbidden, "forbidden: the proxy is not trusted")
                }
                proxyUser(call).ifEmpty { throw HttpError(HttpStatusCode.Forbidden, "forbidden: no proxy user provided") }
            }
            else -> throw HttpError(HttpStatusCode.Unauthorized, "Invalid authentication method: $method")
        }
        return buildJsonObject { put("token", tokens.issue(UserDb(db, user), "webtoken")) }
    }

    private fun proxyUser(call: ApplicationCall) = call.request.headers[config.proxyAuthHeader].orEmpty().trim()

    // %% Reading

    private suspend fun updates(call: ApplicationCall, udb: UserDb): JsonElement {
        val sinceStr = call.request.queryParameters["since"].orEmpty().trim()
        if (sinceStr.isEmpty()) throw HttpError(HttpStatusCode.BadRequest, "bad request: /updates needs since")
        val since = sinceStr.toDoubleOrNull()
            ?: throw HttpError(HttpStatusCode.BadRequest, "bad request: /updates since needs a number (timestamp)")
        val serverTime = now()
        // Early exit, which is what happens most of the time.
        if (udb.mtime() + 0.2 < since) {
            return buildJsonObject {
                put("server_time", serverTime); put("reset", 0)
                put("records", JsonArray(emptyList())); put("settings", JsonArray(emptyList()))
            }
        }
        // The client must reset when the database was reset after `since`.
        val resetTime = udb.io { conn -> udb.userInfo(conn, "reset_time")?.jsonPrimitive?.doubleOrNull } ?: -1.0
        val reset = since <= resetTime
        val (records, settings) = udb.changedSince(if (reset) null else since)
        return buildJsonObject {
            put("server_time", serverTime); put("reset", reset)
            put("records", JsonArray(records.map { it.json() })); put("settings", JsonArray(settings.map { it.json() }))
        }
    }

    private suspend fun getRecords(call: ApplicationCall, udb: UserDb): JsonElement {
        val q = call.request.queryParameters
        val range = q["timerange"].orEmpty().trim()
        if (range.isEmpty()) throw HttpError(HttpStatusCode.BadRequest, "bad request: /records needs timerange (2 timestamps)")
        val parts = range.split("-").map { it.toDoubleOrNull() }
        if (parts.size != 2 || parts.any { it == null }) {
            throw HttpError(HttpStatusCode.BadRequest, "bad request: /records timerange needs 2 numbers (timestamps)")
        }
        fun flag(name: String): Boolean? = q[name].orEmpty().trim().lowercase().let {
            if (it.isEmpty()) null else it !in FALSY
        }
        val tags = q["tag"].orEmpty().trim().replace("#", "").split(",").map { it.trim() }.filter { it.isNotEmpty() }
        val records = udb.records(parts[0]!!.toLong(), parts[1]!!.toLong(), tags, flag("running"), flag("hidden"))
        return buildJsonObject { put("records", JsonArray(records.map { it.json() })) }
    }

    // %% Writing

    /**
     * Stores incoming items. An item older than the stored one is not applied,
     * but every touched item gets a fresh, strictly increasing server time so
     * clients converge on the same state.
     */
    private suspend fun push(call: ApplicationCall, udb: UserDb, what: String): JsonElement {
        val text = call.receiveText()
        if (text.length > BODY_MAX) throw HttpError(HttpStatusCode.PayloadTooLarge, "payload too large")
        val items = runCatching { Json.parseToJsonElement(text) }.getOrNull() as? JsonArray
            ?: throw HttpError(HttpStatusCode.BadRequest, "bad request: list of $what must be a list")
        val serverTime = now()
        val accepted = mutableListOf<String>()
        val failed = mutableListOf<String>()
        val errors = mutableListOf<String>()
        val errors2 = mutableListOf<String>()
        udb.tx { conn ->
            val resetTime = udb.userInfo(conn, "reset_time")?.jsonPrimitive?.doubleOrNull ?: -1.0
            for (raw in items) {
                val key = ((raw as? JsonObject)?.get("key") as? JsonPrimitive)?.takeIf { it.isString }?.content
                if (key == null) {
                    errors2 += "Got item that is not a dict with str 'key' field."
                    continue
                }
                raw as JsonObject
                if (what == "records") {
                    val cur = udb.record(conn, key)
                    var item = try {
                        parseRecord(raw).also { if (it.mt < resetTime) throw IllegalArgumentException("Item was modified after a reset") }
                            .also { accepted += key }
                    } catch (e: IllegalArgumentException) {
                        failed += key
                        errors += e.message.orEmpty()
                        cur ?: continue
                    }
                    if (cur != null && cur.mt > item.mt) item = cur
                    udb.put(conn, item.copy(st = stamp(serverTime, cur?.st)))
                } else {
                    val cur = udb.setting(conn, key)
                    var item = try {
                        parseSetting(raw).also { if (it.mt < resetTime) throw IllegalArgumentException("Item was modified after a reset") }
                            .also { accepted += key }
                    } catch (e: IllegalArgumentException) {
                        failed += key
                        errors += e.message.orEmpty()
                        cur ?: continue
                    }
                    if (cur != null && cur.mt > item.mt) item = cur
                    udb.put(conn, item.copy(st = stamp(serverTime, cur?.st)))
                }
            }
        }
        return buildJsonObject {
            put("accepted", buildJsonArray { accepted.forEach { add(JsonPrimitive(it)) } })
            put("failed", buildJsonArray { failed.forEach { add(JsonPrimitive(it)) } })
            put("errors", buildJsonArray { (errors + errors2).forEach { add(JsonPrimitive(it)) } })
        }
    }

    private fun stamp(serverTime: Double, current: Double?) =
        if (current == null) serverTime else maxOf(serverTime, current + 0.0001)

    private suspend fun ApplicationCall.json(body: JsonElement) =
        respondText(body.toString(), ContentType.Application.Json)

    companion object {
        fun version(): String = Db.resource("version.txt").trim()

        fun parseRecord(o: JsonObject) = Record(
            key = str(o, "key", required = true)!!,
            mt = int(o, "mt") ?: missing("mt"),
            t1 = int(o, "t1") ?: missing("t1"),
            t2 = int(o, "t2") ?: missing("t2"),
            ds = str(o, "ds", required = false) ?: "",
            deleted = int(o, "deleted")?.toInt() ?: 0,
        )

        fun parseSetting(o: JsonObject): Setting {
            val value = o["value"] ?: missing("value")
            if (value.toString().length >= JSON_MAX) throw IllegalArgumentException("Value must be less than $JSON_MAX chars when jsonized.")
            return Setting(key = str(o, "key", required = true)!!, mt = int(o, "mt") ?: missing("mt"), value = value)
        }

        private fun missing(field: String): Nothing = throw IllegalArgumentException("$field: Field required")

        private fun str(o: JsonObject, field: String, required: Boolean): String? {
            val v = o[field]
            if (v == null || v is JsonNull) return if (required) missing(field) else null
            val p = v as? JsonPrimitive
            if (p == null || !p.isString) throw IllegalArgumentException("$field: Input should be a valid string")
            if (p.content.length > STR_MAX - 1) throw IllegalArgumentException("$field: String should have at most ${STR_MAX - 1} characters")
            return p.content
        }

        /** Integers, also as whole floats or numeric strings (like pydantic's lax mode). */
        private fun int(o: JsonObject, field: String): Long? {
            val p = o[field] as? JsonPrimitive ?: return null
            if (p is JsonNull) return null
            val d = p.content.trim().toDoubleOrNull()
            if (d == null || d != Math.floor(d) || d.isInfinite()) throw IllegalArgumentException("$field: Input should be a valid integer")
            return d.toLong()
        }
    }
}

fun Record.json() = buildJsonObject {
    put("key", key); put("mt", mt); put("t1", t1); put("t2", t2); put("ds", ds); put("deleted", deleted); put("st", st)
}

fun Setting.json() = buildJsonObject { put("key", key); put("mt", mt); put("value", value); put("st", st) }
