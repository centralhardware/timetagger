package timetagger.db

import kotliquery.Row
import kotliquery.Session
import kotliquery.queryOf

data class User(val id: Long, val username: String, val passwordHash: String?)

class UserRepository {
    private val select = "SELECT id, username, password_hash FROM users"

    private fun user(row: Row) = User(
        id = row.long("id"),
        username = row.string("username"),
        passwordHash = row.stringOrNull("password_hash"),
    )

    fun byName(session: Session, username: String): User? =
        session.single(queryOf("$select WHERE username = ?", username), ::user)

    fun usernames(session: Session): List<String> =
        session.list(queryOf("SELECT username FROM users ORDER BY username")) { it.string("username") }

    /** Creates the user or replaces the password. */
    fun setPassword(session: Session, username: String, hash: String) {
        session.update(
            queryOf(
                "INSERT INTO users (username, password_hash) VALUES (?, ?) " +
                    "ON CONFLICT (username) DO UPDATE SET password_hash = EXCLUDED.password_hash",
                username, hash,
            ),
        )
    }

    fun delete(session: Session, username: String): Boolean =
        session.update(queryOf("DELETE FROM users WHERE username = ?", username)) == 1

    fun byId(session: Session, id: Long): User? =
        session.single(queryOf("$select WHERE id = ?", id), ::user)
}
