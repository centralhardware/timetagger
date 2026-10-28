package timetagger

import com.zaxxer.hikari.HikariConfig
import com.zaxxer.hikari.HikariDataSource
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import org.slf4j.LoggerFactory
import java.net.URI
import java.net.URLDecoder
import java.sql.Connection
import java.sql.ResultSet

private val log = LoggerFactory.getLogger("timetagger.db")

/** A time record. A running record has t1 == t2. */
data class Record(
    val key: String,
    val mt: Long,
    val t1: Long,
    val t2: Long,
    val ds: String = "",
    val deleted: Int = 0,
    val st: Double? = null,
)

/** A user setting; the value is arbitrary JSON. */
data class Setting(val key: String, val mt: Long, val value: JsonElement, val st: Double? = null)

/**
 * The shared PostgreSQL database. Every row is scoped to a user via the
 * "user" column; the schema comes from the numbered SQL migrations.
 */
class Db(dbUri: String) : AutoCloseable {
    private val ds: HikariDataSource

    init {
        require(dbUri.isNotBlank()) {
            "TimeTagger requires a PostgreSQL database. Set TIMETAGGER_DB_URI, " +
                "e.g. 'postgresql://user:pass@host:5432/timetagger'."
        }
        ds = HikariDataSource(jdbcConfig(dbUri).apply { maximumPoolSize = 10 })
    }

    override fun close() = ds.close()

    suspend fun <T> io(block: (Connection) -> T): T = withContext(Dispatchers.IO) { ds.connection.use(block) }

    /** Runs block in one transaction; rolls back if it throws. */
    suspend fun <T> tx(block: (Connection) -> T): T = io { conn ->
        conn.autoCommit = false
        try {
            block(conn).also { conn.commit() }
        } catch (e: Throwable) {
            conn.rollback()
            throw e
        } finally {
            conn.autoCommit = true
        }
    }

    /** Applies every migration not yet in schema_migrations, each in its own transaction. */
    suspend fun migrate() = io { conn ->
        conn.createStatement().use {
            it.execute(
                "CREATE TABLE IF NOT EXISTS schema_migrations (" +
                    "version integer PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())",
            )
        }
        val applied = conn.createStatement().use { st ->
            st.executeQuery("SELECT version FROM schema_migrations").let { rs ->
                buildSet { while (rs.next()) add(rs.getInt(1)) }
            }
        }
        val names = resource("migrations/index.txt").lines().map { it.trim() }.filter { it.endsWith(".sql") }
        for (name in names.sortedBy { it.substringBefore("_").toInt() }) {
            val version = name.substringBefore("_").toInt()
            if (version in applied) continue
            conn.autoCommit = false
            try {
                conn.createStatement().use { it.execute(resource("migrations/$name")) }
                conn.prepareStatement("INSERT INTO schema_migrations (version) VALUES (?)").use {
                    it.setInt(1, version)
                    it.executeUpdate()
                }
                conn.commit()
            } catch (e: Throwable) {
                conn.rollback()
                throw e
            } finally {
                conn.autoCommit = true
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
            Db::class.java.classLoader.getResource(path)?.readText() ?: error("Missing resource $path")
    }
}

/** Per-user access to the records, settings and userinfo tables. */
class UserDb(private val db: Db, val user: String) {
    private val recordCols =
        "\"key\", modified_time, start_time, stop_time, description, deleted, server_time"

    private fun ResultSet.record() = Record(
        key = getString(1), mt = getLong(2), t1 = getLong(3), t2 = getLong(4),
        ds = getString(5) ?: "", deleted = getInt(6), st = getDouble(7).takeUnless { wasNull() },
    )

    private fun ResultSet.setting() = Setting(
        key = getString(1), mt = getLong(2),
        value = Json.parseToJsonElement(getString(3) ?: "null"), st = getDouble(4).takeUnless { wasNull() },
    )

    /** The latest server_time over all of this user's rows. */
    suspend fun mtime(): Double = db.io { conn ->
        listOf("records", "settings", "userinfo").maxOf { table ->
            conn.prepareStatement("SELECT max(server_time) FROM $table WHERE \"user\" = ?").use { ps ->
                ps.setString(1, user)
                ps.executeQuery().let { rs -> if (rs.next()) rs.getDouble(1).takeUnless { rs.wasNull() } ?: -1.0 else -1.0 }
            }
        }
    }

    /**
     * Records overlapping [t1, t2], plus running records that started before t2.
     * Each tag must appear in the description as "#tag".
     */
    suspend fun records(t1: Long, t2: Long, tags: List<String>, running: Boolean?, hidden: Boolean?): List<Record> =
        db.io { conn ->
            val where = mutableListOf(
                "(stop_time >= ? AND start_time <= ?) OR (start_time = stop_time AND start_time <= ?)",
            )
            val params = mutableListOf<Any>(t1, t2, t2)
            for (tag in tags) {
                val esc = tag.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
                where += "description LIKE ? ESCAPE '\\' OR description LIKE ? ESCAPE '\\'"
                params += "%#$esc %"
                params += "%#$esc"
            }
            when (running) {
                true -> where += "start_time = stop_time"
                false -> where += "start_time != stop_time"
                null -> {}
            }
            when (hidden) {
                true -> where += "deleted = 1"
                false -> where += "deleted = 0"
                null -> {}
            }
            val sql = "SELECT $recordCols FROM records WHERE \"user\" = ? AND " + where.joinToString(" AND ") { "($it)" }
            conn.prepareStatement(sql).use { ps ->
                ps.setString(1, user)
                params.forEachIndexed { i, p -> ps.setObject(i + 2, p) }
                ps.executeQuery().let { rs -> buildList { while (rs.next()) add(rs.record()) } }
            }
        }

    /** Records and settings changed at or after `since`; everything when since is null. */
    suspend fun changedSince(since: Double?): Pair<List<Record>, List<Setting>> = db.io { conn ->
        val cond = if (since == null) "" else " AND server_time >= ?"
        val records = conn.prepareStatement("SELECT $recordCols FROM records WHERE \"user\" = ?$cond").use { ps ->
            ps.setString(1, user)
            since?.let { ps.setDouble(2, it) }
            ps.executeQuery().let { rs -> buildList { while (rs.next()) add(rs.record()) } }
        }
        records to settings(conn, cond, since)
    }

    suspend fun settings(): List<Setting> = db.io { conn -> settings(conn, "", null) }

    private fun settings(conn: Connection, cond: String, since: Double?): List<Setting> =
        conn.prepareStatement(
            "SELECT \"key\", modified_time, value::text, server_time FROM settings WHERE \"user\" = ?$cond",
        ).use { ps ->
            ps.setString(1, user)
            since?.let { ps.setDouble(2, it) }
            ps.executeQuery().let { rs -> buildList { while (rs.next()) add(rs.setting()) } }
        }

    fun record(conn: Connection, key: String): Record? =
        conn.prepareStatement("SELECT $recordCols FROM records WHERE \"user\" = ? AND \"key\" = ?").use { ps ->
            ps.setString(1, user)
            ps.setString(2, key)
            ps.executeQuery().let { rs -> if (rs.next()) rs.record() else null }
        }

    fun setting(conn: Connection, key: String): Setting? =
        conn.prepareStatement(
            "SELECT \"key\", modified_time, value::text, server_time FROM settings WHERE \"user\" = ? AND \"key\" = ?",
        ).use { ps ->
            ps.setString(1, user)
            ps.setString(2, key)
            ps.executeQuery().let { rs -> if (rs.next()) rs.setting() else null }
        }

    fun put(conn: Connection, r: Record) {
        conn.prepareStatement(
            "INSERT INTO records (\"user\", \"key\", modified_time, start_time, stop_time, description, deleted, server_time) " +
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT (\"user\", \"key\") DO UPDATE SET " +
                "modified_time = EXCLUDED.modified_time, start_time = EXCLUDED.start_time, " +
                "stop_time = EXCLUDED.stop_time, description = EXCLUDED.description, " +
                "deleted = EXCLUDED.deleted, server_time = EXCLUDED.server_time",
        ).use { ps ->
            ps.setString(1, user); ps.setString(2, r.key); ps.setLong(3, r.mt); ps.setLong(4, r.t1)
            ps.setLong(5, r.t2); ps.setString(6, r.ds); ps.setInt(7, r.deleted); ps.setDouble(8, r.st ?: 0.0)
            ps.executeUpdate()
        }
    }

    fun put(conn: Connection, s: Setting) = putValue(conn, "settings", s.key, s.mt.toDouble(), s.value, s.st ?: 0.0)

    /** A server-internal userinfo value (token seeds, reset time). */
    fun userInfo(conn: Connection, key: String): JsonElement? =
        conn.prepareStatement("SELECT value::text FROM userinfo WHERE \"user\" = ? AND \"key\" = ?").use { ps ->
            ps.setString(1, user)
            ps.setString(2, key)
            ps.executeQuery().let { rs -> if (rs.next()) rs.getString(1)?.let(Json::parseToJsonElement) else null }
        }

    fun putUserInfo(conn: Connection, key: String, value: JsonElement) {
        val st = now()
        putValue(conn, "userinfo", key, st, value, st)
    }

    private fun putValue(conn: Connection, table: String, key: String, mt: Double, value: JsonElement, st: Double) {
        conn.prepareStatement(
            "INSERT INTO $table (\"user\", \"key\", modified_time, value, server_time) VALUES (?, ?, ?, ?::jsonb, ?) " +
                "ON CONFLICT (\"user\", \"key\") DO UPDATE SET modified_time = EXCLUDED.modified_time, " +
                "value = EXCLUDED.value, server_time = EXCLUDED.server_time",
        ).use { ps ->
            ps.setString(1, user); ps.setString(2, key)
            if (table == "settings") ps.setLong(3, mt.toLong()) else ps.setDouble(3, mt)
            ps.setString(4, value.toString()); ps.setDouble(5, st)
            ps.executeUpdate()
        }
    }

    suspend fun <T> tx(block: (Connection) -> T) = db.tx(block)
    suspend fun <T> io(block: (Connection) -> T) = db.io(block)
}

fun now(): Double = System.currentTimeMillis() / 1000.0
