package timetagger.db

import com.zaxxer.hikari.HikariConfig
import com.zaxxer.hikari.HikariDataSource
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.slf4j.LoggerFactory
import java.net.URI
import java.net.URLDecoder
import java.sql.Connection

private val log = LoggerFactory.getLogger("timetagger.db")

/** The PostgreSQL connection pool; the schema comes from the numbered SQL migrations. */
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

    /** Runs block on a pooled connection, off the request threads. */
    suspend fun <T> io(block: (Connection) -> T): T = withContext(Dispatchers.IO) { ds.connection.use(block) }

    /** Runs block in one transaction; rolls back if it throws. */
    suspend fun <T> tx(block: (Connection) -> T): T = io { conn -> conn.transaction { block(conn) } }

    /** Applies every migration not yet in schema_migrations, each in its own transaction. */
    suspend fun migrate() = io { conn ->
        conn.createStatement().use {
            it.execute(
                "CREATE TABLE IF NOT EXISTS schema_migrations (" +
                    "version integer PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())",
            )
        }
        val applied = conn.prepareStatement("SELECT version FROM schema_migrations").use { ps ->
            ps.executeQuery().list { getInt(1) }.toSet()
        }
        val names = resource("migrations/index.txt").lines().map { it.trim() }.filter { it.endsWith(".sql") }
        for (name in names.sortedBy { it.substringBefore("_").toInt() }) {
            val version = name.substringBefore("_").toInt()
            if (version in applied) continue
            conn.transaction {
                conn.createStatement().use { it.execute(resource("migrations/$name")) }
                conn.update("INSERT INTO schema_migrations (version) VALUES (?)", version)
            }
            log.info("Applied database migration {}", name)
        }
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
