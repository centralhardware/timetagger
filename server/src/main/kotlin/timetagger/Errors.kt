package timetagger

import io.ktor.http.HttpStatusCode

/** An error answered as plain text with the given status, like the Python server did. */
class ApiException(val status: HttpStatusCode, message: String) : Exception(message)

fun badRequest(message: String): Nothing = throw ApiException(HttpStatusCode.BadRequest, "bad request: $message")
