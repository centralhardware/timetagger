package timetagger.auth

import at.favre.lib.crypto.bcrypt.BCrypt
import timetagger.db.Database
import timetagger.db.RefreshTokenRepository
import timetagger.db.UserRepository

/** Username/password logins, bcrypt-hashed. */
class PasswordService(
    private val db: Database,
    private val users: UserRepository,
    private val refreshTokens: RefreshTokenRepository = RefreshTokenRepository(),
) {
    suspend fun set(username: String, password: String) {
        val user = username.trim()
        require(user.isNotEmpty()) { "Username must not be empty" }
        require(password.isNotEmpty()) { "Password must not be empty" }
        val hash = BCrypt.with(BCrypt.Version.VERSION_2B).hashToString(12, password.toCharArray())
        db.tx { session ->
            users.setPassword(session, user, hash)
            // A new password signs out every session made with the old one.
            users.byName(session, user)?.let { refreshTokens.revokeAll(session, it.id) }
        }
    }

    suspend fun verify(username: String, password: String): Boolean {
        val user = username.trim()
        if (user.isEmpty() || password.isEmpty()) return false
        val hash = db.io { users.byName(it, user) }?.passwordHash ?: return false
        return runCatching { BCrypt.verifyer().verify(password.toCharArray(), hash).verified }.getOrDefault(false)
    }

    suspend fun delete(username: String): Boolean = db.io { users.delete(it, username.trim()) }

    suspend fun list(): List<String> = db.io { users.usernames(it) }
}
