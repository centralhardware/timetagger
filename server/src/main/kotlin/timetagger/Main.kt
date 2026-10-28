package timetagger

import io.ktor.http.HttpStatusCode
import io.ktor.server.application.Application
import io.ktor.server.cio.CIO
import io.ktor.server.engine.embeddedServer
import io.ktor.server.request.path
import io.ktor.server.response.respondText
import io.ktor.server.routing.route
import io.ktor.server.routing.routing
import io.ktor.server.routing.get
import kotlinx.coroutines.runBlocking
import kotlin.system.exitProcess

private val userCommands = setOf(
    "user-list", "users", "user-add", "user-set", "user-set-password", "user-remove", "user-del", "user-delete",
)

fun main(args: Array<String>) {
    val config = Config.load(args.toList())
    when (args.firstOrNull()) {
        "version", "--version" -> {
            println("timetagger ${Api.version()}")
            return
        }
        in userCommands -> exitProcess(runBlocking { userAdmin(config, args[0], args.drop(1)) })
    }
    val db = Db(config.dbUri)
    runBlocking { db.migrate() }
    embeddedServer(CIO, host = config.host, port = config.port) { module(config, db) }.start(wait = true)
}

fun Application.module(config: Config, db: Db) {
    val api = Api(config, db, Tokens(config.jwtKey), Credentials(db))
    val prefix = config.pathPrefix
    routing {
        get("${prefix}status") { call.respondText("ok") }
        route("${prefix}api/v2/{path...}") {
            handle { api.handle(call, call.request.path().removePrefix("${prefix}api/v2").trim('/')) }
        }
        route("{...}") {
            handle { call.respondText("not found: only serving the API at ${prefix}api/v2/", status = HttpStatusCode.NotFound) }
        }
    }
}

/** The `user-*` commands that manage login credentials. */
private suspend fun userAdmin(config: Config, cmd: String, args: List<String>): Int = Db(config.dbUri).use { db ->
    db.migrate()
    val creds = Credentials(db)
    when (cmd) {
        "user-list", "users" -> println(creds.list().joinToString("\n").ifEmpty { "(no users)" })
        "user-add", "user-set", "user-set-password" -> {
            if (args.size < 2) return 2.also { println("Usage: timetagger $cmd <username> <password>") }
            creds.set(args[0], args[1])
            println("Saved credentials for user '${args[0]}'.")
        }
        else -> {
            if (args.isEmpty()) return 2.also { println("Usage: timetagger $cmd <username>") }
            println(if (creds.delete(args[0])) "Removed user '${args[0]}'." else "No such user.")
        }
    }
    0
}
