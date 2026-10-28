package timetagger.model

import kotlinx.serialization.Serializable

@Serializable
data class LoginRequest(val username: String, val password: String)

@Serializable
data class RefreshRequest(val refreshToken: String)

@Serializable
data class TokenPairResponse(
    val accessToken: String,
    val accessExpiresAt: IsoInstant,
    val refreshToken: String,
    val refreshExpiresAt: IsoInstant,
)

/** A signed-in device: one refresh-token family, shown by its latest token. */
@Serializable
data class SessionInfo(val id: String, val userAgent: String?, val lastRefreshedAt: IsoInstant, val expiresAt: IsoInstant)

@Serializable
data class SessionList(val sessions: List<SessionInfo>)

@Serializable
data class CreateApiKey(val name: String = "")

@Serializable
data class ApiKeyInfo(
    val id: Long,
    val name: String,
    /** The key's first characters, to tell keys apart. */
    val prefix: String,
    val createdAt: IsoInstant,
    val lastUsedAt: IsoInstant?,
    /** Only in the answer to its creation; never again. */
    val key: String? = null,
)

@Serializable
data class ApiKeyList(val apiKeys: List<ApiKeyInfo>)

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
