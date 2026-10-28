package timetagger

import io.ktor.server.cio.CIO
import io.ktor.server.engine.embeddedServer
import kotlinx.coroutines.runBlocking
import timetagger.cli.USER_COMMANDS
import timetagger.cli.runUserCommand
import timetagger.config.Config
import timetagger.db.Database
import kotlin.system.exitProcess

fun main(args: Array<String>) {
    val config = Config.load(args.toList())
    when (args.firstOrNull()) {
        "version", "--version" -> return println("timetagger ${version()}")
        in USER_COMMANDS -> exitProcess(runBlocking { runUserCommand(config, args[0], args.drop(1)) })
    }
    val db = Database(config.dbUri)
    runBlocking { db.migrate() }
    embeddedServer(CIO, host = config.host, port = config.port) { module(config, db) }.start(wait = true)
}
