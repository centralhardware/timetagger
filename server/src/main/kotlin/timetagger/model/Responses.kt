package timetagger.model

import kotlinx.serialization.Serializable

@Serializable
data class TokenResponse(val token: String, val expiresAt: IsoInstant)

@Serializable
data class Me(val username: String)

@Serializable
data class VersionResponse(val version: String)

/** Everything written after revision `since`, and the revision to pass next time. */
@Serializable
data class Changes(val revision: Long, val records: List<Record>, val settings: List<Setting>)

/** Every error response: a machine-readable code and a human message. */
@Serializable
data class ErrorResponse(val error: String, val message: String, val current: Record? = null)
