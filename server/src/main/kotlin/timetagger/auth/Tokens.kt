package timetagger.auth

import com.auth0.jwt.JWT
import com.auth0.jwt.JWTVerifier
import com.auth0.jwt.algorithms.Algorithm
import com.auth0.jwt.interfaces.Payload
import org.slf4j.LoggerFactory
import timetagger.db.Database
import timetagger.db.UserRepository
import java.security.SecureRandom
import java.time.Duration
import java.time.Instant
import java.time.temporal.ChronoUnit
import java.util.Base64

private val log = LoggerFactory.getLogger("timetagger.auth")

/** The authenticated user, as carried in a token. */
data class AuthInfo(val userId: Long, val username: String, val kind: TokenKind, val expiresAt: Instant)

/** Web tokens come from a login and expire; API tokens are long-lived and made from a web token. */
enum class TokenKind(val id: String, val seedColumn: String, val lifetime: Duration) {
    WEB("web", "web_token_seed", Duration.ofDays(14)),
    API("api", "api_token_seed", Duration.ofDays(365L * 100)),
    ;

    companion object {
        fun of(id: String) = entries.firstOrNull { it.id == id }
    }
}

/** Signs and verifies the HS256 tokens. */
class JwtCodec(key: String) {
    private val algorithm = Algorithm.HMAC256(
        key.trim().ifEmpty {
            log.warn("TIMETAGGER_JWT_KEY is not set; using an ephemeral key. All sessions end when the server restarts.")
            TokenService.randomToken(32)
        },
    )

    /** Checks the signature and expiry; [TokenService.validate] checks the seed. */
    val verifier: JWTVerifier = JWT.require(algorithm).build()

    fun encode(username: String, kind: TokenKind, seed: String, expiresAt: Instant): String = JWT.create()
        .withSubject(username)
        .withClaim("kind", kind.id)
        .withClaim("seed", seed)
        .withExpiresAt(expiresAt)
        .sign(algorithm)
}

/**
 * Issues and validates tokens. Each user has one seed per kind; a new seed
 * revokes every token of that kind.
 */
class TokenService(private val codec: JwtCodec, private val db: Database, private val users: UserRepository) {
    /** A token for a user who has already authenticated. */
    suspend fun issue(username: String, kind: TokenKind): Pair<String, Instant> = db.tx { session ->
        val user = users.byName(session, username) ?: error("no user $username")
        val seed = (if (kind == TokenKind.WEB) user.webTokenSeed else user.apiTokenSeed)
            ?: randomToken(8).also { users.setSeed(session, user.id, kind.seedColumn, it) }
        val expiresAt = Instant.now().plus(kind.lifetime).truncatedTo(ChronoUnit.SECONDS)
        codec.encode(username, kind, seed, expiresAt) to expiresAt
    }

    /** Revokes every token of that kind for the user. */
    suspend fun revoke(userId: Long, kind: TokenKind) =
        db.tx { users.setSeed(it, userId, kind.seedColumn, randomToken(8)) }

    /** The token's user if its seed is still current. Signature and expiry were checked by the jwt provider. */
    suspend fun validate(payload: Payload): AuthInfo? {
        val username = payload.subject ?: return null
        val kind = TokenKind.of(payload.getClaim("kind").asString() ?: return null) ?: return null
        val seed = payload.getClaim("seed").asString() ?: return null
        val user = db.io { users.byName(it, username) } ?: return null
        val current = if (kind == TokenKind.WEB) user.webTokenSeed else user.apiTokenSeed
        return AuthInfo(user.id, user.username, kind, payload.expiresAtAsInstant).takeIf { seed == current }
    }

    companion object {
        private val random = SecureRandom()

        fun randomToken(bytes: Int): String =
            Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(bytes).also(random::nextBytes))
    }
}
