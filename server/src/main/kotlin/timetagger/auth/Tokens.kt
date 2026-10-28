package timetagger.auth

import com.auth0.jwt.JWT
import com.auth0.jwt.JWTVerifier
import com.auth0.jwt.algorithms.Algorithm
import com.auth0.jwt.interfaces.Payload
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import org.slf4j.LoggerFactory
import timetagger.db.Database
import timetagger.db.UserInfoRepository
import timetagger.now
import java.security.SecureRandom
import java.util.Base64

private val log = LoggerFactory.getLogger("timetagger.auth")

const val WEBTOKEN_DAYS = 14
const val WEBTOKEN_LIFETIME = WEBTOKEN_DAYS * 24 * 60 * 60L
const val API_TOKEN_EXP = 32503748400L // the year 3000

/** The authenticated user, as carried in a token. */
data class AuthInfo(val username: String, val expires: Long, val seed: String) {
    /** API tokens live far longer than a web token can. */
    val isApiToken: Boolean get() = expires > now() + WEBTOKEN_LIFETIME
}

enum class TokenKind(val id: String) { WEB("webtoken"), API("apitoken") }

/** Signs and verifies the HS256 tokens; compatible with the Python server's. */
class JwtCodec(key: String) {
    private val algorithm = Algorithm.HMAC256(
        key.trim().ifEmpty {
            log.warn("TIMETAGGER_JWT_KEY is not set; using an ephemeral key. All sessions end when the server restarts.")
            TokenService.randomToken(32)
        },
    )

    /** Checks the signature only; [TokenService.validate] checks seed and expiry. */
    val verifier: JWTVerifier = JWT.require(algorithm).build()

    fun encode(info: AuthInfo): String = JWT.create()
        .withClaim("username", info.username)
        .withClaim("expires", info.expires)
        .withClaim("seed", info.seed)
        .sign(algorithm)

    fun decode(token: String): AuthInfo? = runCatching { verifier.verify(token) }.getOrNull()?.let(::info)

    companion object {
        fun info(payload: Payload): AuthInfo? = AuthInfo(
            username = payload.getClaim("username").asString() ?: return null,
            expires = payload.getClaim("expires").asDouble()?.toLong() ?: return null,
            seed = payload.getClaim("seed").asString() ?: return null,
        )
    }
}

/**
 * Issues and validates tokens. Each kind has a per-user seed in userinfo;
 * a new seed revokes every token of that kind.
 */
class TokenService(private val codec: JwtCodec, private val db: Database, private val userInfo: UserInfoRepository) {
    /** A token of the given kind; the caller must already have authenticated the user. */
    suspend fun issue(username: String, kind: TokenKind, reset: Boolean = false): String {
        val expires = if (kind == TokenKind.API) API_TOKEN_EXP else (now() + WEBTOKEN_LIFETIME).toLong()
        return codec.encode(AuthInfo(username, expires, seed(username, kind, reset)))
    }

    /**
     * The token's user if its seed is current (not revoked) and it has not expired;
     * the signature was already checked by the jwt provider.
     */
    suspend fun validate(payload: Payload): AuthInfo? {
        val info = JwtCodec.info(payload) ?: return null
        val kind = if (info.isApiToken) TokenKind.API else TokenKind.WEB
        return info.takeIf { seed(it.username, kind, false) == it.seed && it.expires >= now() }
    }

    private suspend fun seed(username: String, kind: TokenKind, reset: Boolean): String = db.tx { session ->
        val key = "${kind.id}_seed"
        val current = userInfo.get(session, username, key)?.jsonPrimitive?.contentOrNull.orEmpty()
        if (!reset && current.isNotEmpty()) current
        else randomToken(8).also { userInfo.put(session, username, key, JsonPrimitive(it), now()) }
    }

    companion object {
        private val random = SecureRandom()

        /** Like Python's secrets.token_urlsafe(n). */
        fun randomToken(bytes: Int): String =
            Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(bytes).also(random::nextBytes))
    }
}
