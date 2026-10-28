package timetagger.routes

import io.ktor.server.auth.principal
import io.ktor.server.application.ApplicationCall
import io.ktor.server.routing.RoutingCall
import timetagger.Invalid
import timetagger.auth.AuthInfo
import java.time.Instant
import java.time.format.DateTimeParseException

/** The authenticated user; only valid inside an authenticated route. */
val ApplicationCall.auth: AuthInfo get() = principal<AuthInfo>()!!

fun RoutingCall.path(name: String): String = parameters[name]!!

fun RoutingCall.boolParam(name: String): Boolean? = request.queryParameters[name]?.let {
    it.toBooleanStrictOrNull() ?: throw Invalid("$name must be true or false")
}

fun RoutingCall.instantParam(name: String): Instant? = request.queryParameters[name]?.let {
    try {
        Instant.parse(it)
    } catch (e: DateTimeParseException) {
        throw Invalid("$name must be an ISO-8601 instant, e.g. 2026-10-28T00:00:00Z")
    }
}
