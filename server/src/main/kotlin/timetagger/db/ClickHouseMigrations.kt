package timetagger.db

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonPrimitive
import org.slf4j.LoggerFactory

private val log = LoggerFactory.getLogger("timetagger.clickhouse")

/**
 * Versioned ClickHouse migrations, the Flyway way: `clickhouse/migration/V<n>__<name>.sql`, one
 * statement per file, applied in order once each and recorded in `schema_migrations`.
 * Flyway itself has no ClickHouse support in the open-source edition, hence this.
 */
class ClickHouseMigrations(private val ch: ClickHouse) {
    data class Migration(val version: Int, val name: String, val sql: String)

    suspend fun migrate() {
        ch.execute(
            """
            CREATE TABLE IF NOT EXISTS schema_migrations (
                version    UInt32,
                name       String,
                applied_at DateTime64(3, 'UTC') DEFAULT now64(3)
            )
            ENGINE = MergeTree ORDER BY version
            """.trimIndent(),
        )
        val applied = ch.select("SELECT version FROM schema_migrations").map { it["version"]!!.jsonPrimitive.content.toInt() }.toSet()
        for (m in available().filter { it.version !in applied }) {
            log.info("Applying ClickHouse migration V{}__{}", m.version, m.name)
            ch.execute(m.sql)
            ch.insert("schema_migrations", listOf(JsonObject(mapOf("version" to JsonPrimitive(m.version), "name" to JsonPrimitive(m.name)))))
        }
    }

    companion object {
        private val FILE = Regex("V(\\d+)__(\\w+)\\.sql")

        /** The migrations on the classpath, listed in `clickhouse/migration/index.txt`, in version order. */
        fun available(): List<Migration> =
            Database.resource("clickhouse/migration/index.txt").lines().map { it.trim() }.filter { it.isNotEmpty() }.map { file ->
                val m = FILE.matchEntire(file) ?: error("bad ClickHouse migration name $file")
                val sql = Database.resource("clickhouse/migration/$file").lines()
                    .filterNot { it.trimStart().startsWith("--") }.joinToString("\n").trim().trimEnd(';')
                Migration(m.groupValues[1].toInt(), m.groupValues[2], sql)
            }.sortedBy { it.version }.also { ms ->
                require(ms.map { it.version }.distinct().size == ms.size) { "duplicate ClickHouse migration version" }
            }
    }
}
