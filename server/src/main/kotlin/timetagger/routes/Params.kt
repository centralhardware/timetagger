package timetagger.routes

import io.ktor.server.auth.principal
import io.ktor.server.request.receiveText
import io.ktor.server.routing.RoutingCall
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import timetagger.auth.AuthInfo
import timetagger.badRequest

private val FALSY = setOf("false", "off", "no", "n", "0")
private const val BODY_MAX = 10 * 1024 * 1024

/** The authenticated user; only valid inside an authenticated route. */
val RoutingCall.user: AuthInfo get() = principal<AuthInfo>()!!

/** A yes/no query flag: absent → null, a falsy word → false, anything else → true. */
fun RoutingCall.flag(name: String): Boolean? =
    request.queryParameters[name].orEmpty().trim().lowercase().let { if (it.isEmpty()) null else it !in FALSY }

/** The request body as a JSON list. Read as text, so clients need not set a content type. */
suspend fun RoutingCall.receiveList(what: String): JsonArray {
    val text = receiveText()
    if (text.length > BODY_MAX) badRequest("body too large")
    return runCatching { Json.parseToJsonElement(text) }.getOrNull() as? JsonArray ?: badRequest("list of $what must be a list")
}
