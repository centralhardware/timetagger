package timetagger.db

import com.zaxxer.hikari.HikariConfig
import com.zaxxer.hikari.HikariDataSource
import kotliquery.Session
import kotliquery.TransactionalSession
import kotliquery.queryOf
import kotliquery.sessionOf
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
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

    private val committed = MutableSharedFlow<Long>(extraBufferCapacity = 64, onBufferOverflow = BufferOverflow.DROP_OLDEST)

    /** The id of every user whose write has just committed. */
    val writes: SharedFlow<Long> = committed

    /** Runs block in a session, off the request threads. */
    suspend fun <T> io(block: (Session) -> T): T = withContext(Dispatchers.IO) { sessionOf(ds).use(block) }

    /** Runs block in one transaction; rolls back if it throws. */
    suspend fun <T> tx(block: (TransactionalSession) -> T): T = io { session -> session.transaction(block) }

    /**
     * One of the user's writes. Locking the user's row queues their writes one after another,
     * so a revision is never visible before a lower one that commits later; GET /changes
     * would skip that one for good. [writes] hears of it once it has committed.
     */
    suspend fun <T> write(userId: Long, block: (TransactionalSession) -> T): T =
        tx { session ->
            session.single(queryOf("SELECT id FROM users WHERE id = ? FOR UPDATE", userId)) { it.long("id") }
            block(session)
        }.also { committed.tryEmit(userId) }

    /** Runs block in a read-only transaction that sees one snapshot throughout. */
    suspend fun <T> snapshot(block: (TransactionalSession) -> T): T = tx { session ->
        session.execute(queryOf("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY"))
        block(session)
    }

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
