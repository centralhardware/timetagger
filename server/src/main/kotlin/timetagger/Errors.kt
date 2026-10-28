package timetagger

import io.ktor.http.HttpStatusCode
import timetagger.model.Record

/** An error answered as JSON `{error, message}` with the given status. */
open class ApiException(val status: HttpStatusCode, val code: String, message: String) : Exception(message)

class NotFound(what: String) : ApiException(HttpStatusCode.NotFound, "not_found", "$what not found")

class Invalid(message: String) : ApiException(HttpStatusCode.UnprocessableEntity, "invalid", message)

/** The stored record was edited more recently than the incoming one. */
class Conflict(val current: Record) :
    ApiException(HttpStatusCode.Conflict, "conflict", "record ${current.key} has a newer edit (${current.modifiedAt})")
