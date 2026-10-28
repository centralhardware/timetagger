package timetagger.db

import com.zaxxer.hikari.HikariConfig
import com.zaxxer.hikari.HikariDataSource
import kotliquery.Session
import kotliquery.TransactionalSession
import kotliquery.queryOf
import kotliquery.sessionOf
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.flywaydb.core.Flyway
import java.net.URI
import java.net.URLDecoder

/** The PostgreSQL connection pool. The schema comes from the Flyway migrations in db/migration. */
class Database(dbUri: String) : AutoCloseable {
    private val ds: HikariDataSource

    init {
        require(dbUri.isNotBlank()) {
            "TimeTagger requires a PostgreSQL database. Set TIMETAGGER_DB_URI, " +
                "e.g. 'postgresql://user:pass@host:5432/timetagger'."
        }
        ds = HikariDataSource(jdbcConfig(dbUri).apply { maximumPoolSize = 10 })
    }

    override fun close() = ds.close()

    /** Runs block in a session, off the request threads. */
    suspend fun <T> io(block: (Session) -> T): T = withContext(Dispatchers.IO) { sessionOf(ds).use(block) }

    /** Runs block in one transaction; rolls back if it throws. */
    suspend fun <T> tx(block: (TransactionalSession) -> T): T = io { session -> session.transaction(block) }

    /**
     * Applies pending migrations. A database from the Python server tracked
     * migrations 1–4 in its own schema_migrations table; Flyway adopts it at
     * version 4 instead of re-running them.
     */
    fun migrate() {
        val flyway = Flyway.configure().dataSource(ds).locations("classpath:db/migration").baselineVersion("4").load()
        val fromPython = sessionOf(ds).use { s ->
            fun exists(table: String) = s.single(queryOf("SELECT to_regclass(?) IS NOT NULL AS e", table)) { it.boolean("e") } == true
            exists("schema_migrations") && !exists("flyway_schema_history")
        }
        if (fromPython) flyway.baseline()
        flyway.migrate()
    }

    companion object {
        /** Turns a postgresql://user:pass@host:port/db URI into a Hikari config. */
        fun jdbcConfig(uri: String): HikariConfig {
            val u = URI(uri.trim().replaceFirst(Regex("^postgres(ql)?://"), "http://"))
            return HikariConfig().apply {
                jdbcUrl = "jdbc:postgresql://${u.host}:${if (u.port > 0) u.port else 5432}${u.rawPath}" +
                    (u.rawQuery?.let { "?$it" } ?: "")
                u.rawUserInfo?.let { info ->
                    username = URLDecoder.decode(info.substringBefore(":"), Charsets.UTF_8)
                    if (":" in info) password = URLDecoder.decode(info.substringAfter(":"), Charsets.UTF_8)
                }
            }
        }

        fun resource(path: String): String =
            Database::class.java.classLoader.getResource(path)?.readText() ?: error("Missing resource $path")
    }
}
