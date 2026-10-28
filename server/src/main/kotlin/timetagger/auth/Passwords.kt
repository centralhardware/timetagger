package timetagger.auth

import at.favre.lib.crypto.bcrypt.BCrypt
import timetagger.db.CredentialRepository
import timetagger.db.Database
import timetagger.now

/** Username/password logins; hashes are bcrypt `$2b$`, like the Python server's. */
class PasswordService(private val db: Database, private val credentials: CredentialRepository) {
    suspend fun set(username: String, password: String) {
        val user = username.trim()
        require(user.isNotEmpty()) { "Username must not be empty" }
        require(password.isNotEmpty()) { "Password must not be empty" }
        val hash = BCrypt.with(BCrypt.Version.VERSION_2B).hashToString(12, password.toCharArray())
        db.io { credentials.upsert(it, user, hash, now()) }
    }

    suspend fun verify(username: String, password: String): Boolean {
        val user = username.trim()
        if (user.isEmpty() || password.isEmpty()) return false
        val hash = db.io { credentials.hash(it, user) } ?: return false
        return runCatching { BCrypt.verifyer().verify(password.toCharArray(), hash).verified }.getOrDefault(false)
    }

    suspend fun delete(username: String): Boolean = db.io { credentials.delete(it, username.trim()) }

    suspend fun list(): List<String> = db.io { credentials.usernames(it) }
}
