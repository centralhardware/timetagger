package timetagger.model

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonPrimitive

@Serializable
data class TokenResponse(val token: String)

@Serializable
data class VersionResponse(val version: String)

@Serializable
data class StatusResponse(val status: String)

@Serializable
data class RecordsResponse(val records: List<Record>)

@Serializable
data class SettingsResponse(val settings: List<Setting>)

/** What changed since the client's last sync; `reset` asks the client to drop its local state. */
@Serializable
data class UpdatesResponse(
    val server_time: Double,
    /** `true`/`false`, or `0` on the fast path where nothing changed. */
    val reset: JsonPrimitive,
    val records: List<Record>,
    val settings: List<Setting>,
)

/** Keys stored, keys rejected and why; errors for items without a key come last. */
@Serializable
data class PushResponse(val accepted: List<String>, val failed: List<String>, val errors: List<String>)
