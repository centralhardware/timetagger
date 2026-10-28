package timetagger

import at.favre.lib.crypto.bcrypt.BCrypt
import com.auth0.jwt.JWT
import com.auth0.jwt.algorithms.Algorithm
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import org.slf4j.LoggerFactory
import java.net.InetAddress
import java.security.SecureRandom
import java.util.Base64

private val log = LoggerFactory.getLogger("timetagger.auth")

const val WEBTOKEN_DAYS = 14
const val WEBTOKEN_LIFETIME = WEBTOKEN_DAYS * 24 * 60 * 60L
const val API_TOKEN_EXP = 32503748400L // the year 3000

class AuthException(message: String) : Exception(message)

data class AuthInfo(val username: String, val expires: Long, val seed: String)

/** Issues and checks the HS256 tokens; compatible with tokens from the Python server. */
class Tokens(key: String) {
    private val algorithm = Algorithm.HMAC256(
        key.trim().ifEmpty {
            log.warn(
                "TIMETAGGER_JWT_KEY is not set; using an ephemeral key. All sessions " +
                    "will be invalidated when the server restarts.",
            )
            randomToken(32)
        },
    )

    fun create(info: AuthInfo): String = JWT.create()
        .withClaim("username", info.username)
        .withClaim("expires", info.expires)
        .withClaim("seed", info.seed)
        .sign(algorithm)

    fun decode(token: String): AuthInfo {
        val jwt = try {
            JWT.require(algorithm).build().verify(token)
        } catch (e: Exception) {
            throw AuthException(e.message ?: "invalid token")
        }
        return AuthInfo(
            username = jwt.getClaim("username").asString() ?: throw AuthException("token has no username"),
            expires = jwt.getClaim("expires").asDouble()?.toLong() ?: throw AuthException("token has no expires"),
            seed = jwt.getClaim("seed").asString() ?: throw AuthException("token has no seed"),
        )
    }

    /** The token's seed lives in userinfo; resetting it revokes every token of that kind. */
    suspend fun seed(udb: UserDb, kind: String, reset: Boolean): String = udb.tx { conn ->
        val current = udb.userInfo(conn, "${kind}_seed")?.jsonPrimitive?.contentOrNull.orEmpty()
        if (!reset && current.isNotEmpty()) {
            current
        } else {
            randomToken(8).also { udb.putUserInfo(conn, "${kind}_seed", JsonPrimitive(it)) }
        }
    }

    /** A token of the given kind; the caller must already have authenticated the user. */
    suspend fun issue(udb: UserDb, kind: String, reset: Boolean = false): String {
        val expires = if (kind == "apitoken") API_TOKEN_EXP else (now() + WEBTOKEN_LIFETIME).toLong()
        return create(AuthInfo(udb.user, expires, seed(udb, kind, reset)))
    }

    /** Validates a token: issued by us, seed not revoked, not expired (checked in that order). */
    suspend fun authenticate(db: Db, token: String): AuthInfo {
        if (token.isEmpty()) throw AuthException("Missing jwt 'authtoken' in header.")
        val info = decode(token)
        val kind = if (info.expires > now() + WEBTOKEN_LIFETIME) "apitoken" else "webtoken"
        val ref = seed(UserDb(db, info.username), kind, false)
        if (ref != info.seed) throw AuthException("The $kind is revoked (seed does not match)")
        if (info.expires < now()) throw AuthException("The $kind has expired (after $WEBTOKEN_DAYS days)")
        return info
    }

    companion object {
        private val random = SecureRandom()

        /** Like Python's secrets.token_urlsafe(n). */
        fun randomToken(bytes: Int): String =
            Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(bytes).also(random::nextBytes))
    }
}

/** Login credentials, stored bcrypt-hashed in the credentials table. */
class Credentials(private val db: Db) {
    suspend fun set(username: String, password: String) {
        val user = username.trim()
        require(user.isNotEmpty()) { "Username must not be empty" }
        require(password.isNotEmpty()) { "Password must not be empty" }
        val hash = BCrypt.with(BCrypt.Version.VERSION_2B).hashToString(12, password.toCharArray())
        db.io { conn ->
            conn.prepareStatement(
                "INSERT INTO credentials (username, pw_hash, modified_time) VALUES (?, ?, ?) " +
                    "ON CONFLICT (username) DO UPDATE SET pw_hash = EXCLUDED.pw_hash, modified_time = EXCLUDED.modified_time",
            ).use { ps ->
                ps.setString(1, user); ps.setString(2, hash); ps.setDouble(3, now())
                ps.executeUpdate()
            }
        }
    }

    suspend fun verify(username: String, password: String): Boolean {
        val user = username.trim()
        if (user.isEmpty() || password.isEmpty()) return false
        val hash = db.io { conn ->
            conn.prepareStatement("SELECT pw_hash FROM credentials WHERE username = ?").use { ps ->
                ps.setString(1, user)
                ps.executeQuery().let { rs -> if (rs.next()) rs.getString(1) else null }
            }
        } ?: return false
        return runCatching { BCrypt.verifyer().verify(password.toCharArray(), hash).verified }.getOrDefault(false)
    }

    suspend fun delete(username: String): Boolean = db.io { conn ->
        conn.prepareStatement("DELETE FROM credentials WHERE username = ?").use { ps ->
            ps.setString(1, username.trim())
            ps.executeUpdate() == 1
        }
    }

    suspend fun list(): List<String> = db.io { conn ->
        conn.createStatement().use { st ->
            st.executeQuery("SELECT username FROM credentials ORDER BY username").let { rs ->
                buildList { while (rs.next()) add(rs.getString(1)) }
            }
        }
    }
}

/** IPv4/IPv6 ranges like "10.99.0.0/24", "192.168/16" or a single address. */
class IpRanges(spec: String) {
    private val ranges = spec.replace(";", ",").split(",").map { it.trim() }.filter { it.isNotEmpty() }.map(::parse)

    fun contains(ip: String): Boolean {
        val addr = runCatching { InetAddress.getByName(ip).address }.getOrNull() ?: return false
        return ranges.any { (net, bits) -> net.size == addr.size && matches(net, addr, bits) }
    }

    private fun parse(s: String): Pair<ByteArray, Int> {
        val host = s.substringBefore("/")
        // Short IPv4 forms like "192.168" are padded with zeros, as in Python's iptools.
        val full = if (":" !in host && host.count { it == '.' } < 3) {
            (host.split(".") + List(3 - host.count { it == '.' }) { "0" }).joinToString(".")
        } else {
            host
        }
        val addr = InetAddress.getByName(full).address
        val bits = if ("/" in s) s.substringAfter("/").toInt() else addr.size * 8
        return addr to bits
    }

    private fun matches(net: ByteArray, addr: ByteArray, bits: Int): Boolean {
        for (i in net.indices) {
            val take = (bits - i * 8).coerceIn(0, 8)
            if (take == 0) return true
            val mask = (0xFF shl (8 - take)) and 0xFF
            if ((net[i].toInt() and mask) != (addr[i].toInt() and mask)) return false
        }
        return true
    }
}
