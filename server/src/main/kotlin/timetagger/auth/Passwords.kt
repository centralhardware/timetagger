package timetagger.auth

import at.favre.lib.crypto.bcrypt.BCrypt
import timetagger.db.Database
import timetagger.db.UserRepository

/** Username/password logins, bcrypt-hashed. */
class PasswordService(private val db: Database, private val users: UserRepository) {
    suspend fun set(username: String, password: String) {
        val user = username.trim()
        require(user.isNotEmpty()) { "Username must not be empty" }
        require(password.isNotEmpty()) { "Password must not be empty" }
        val hash = BCrypt.with(BCrypt.Version.VERSION_2B).hashToString(12, password.toCharArray())
        db.io { users.setPassword(it, user, hash) }
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
