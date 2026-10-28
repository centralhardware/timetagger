package timetagger.cli

import timetagger.auth.PasswordService
import timetagger.config.Config
import timetagger.db.CredentialRepository
import timetagger.db.Database

val USER_COMMANDS = setOf("user-list", "users", "user-add", "user-set", "user-set-password", "user-remove", "user-del", "user-delete")

/** The `user-*` commands that manage login credentials; returns the exit code. */
suspend fun runUserCommand(config: Config, cmd: String, args: List<String>): Int = Database(config.dbUri).use { db ->
    db.migrate()
    val passwords = PasswordService(db, CredentialRepository())
    when (cmd) {
        "user-list", "users" -> println(passwords.list().joinToString("\n").ifEmpty { "(no users)" })
        "user-add", "user-set", "user-set-password" -> {
            if (args.size < 2) return 2.also { println("Usage: timetagger $cmd <username> <password>") }
            passwords.set(args[0], args[1])
            println("Saved credentials for user '${args[0]}'.")
        }
        else -> {
            if (args.isEmpty()) return 2.also { println("Usage: timetagger $cmd <username>") }
            println(if (passwords.delete(args[0])) "Removed user '${args[0]}'." else "No such user.")
        }
    }
    0
}
