package timetagger.db

import java.sql.Connection
import java.sql.PreparedStatement
import java.sql.ResultSet

/** Small JDBC helpers so the repositories read as SQL plus mapping. */

fun <T> Connection.transaction(block: () -> T): T {
    autoCommit = false
    try {
        return block().also { commit() }
    } catch (e: Throwable) {
        rollback()
        throw e
    } finally {
        autoCommit = true
    }
}

fun PreparedStatement.bind(params: List<Any?>): PreparedStatement = apply {
    params.forEachIndexed { i, p -> setObject(i + 1, p) }
}

fun <T> Connection.query(sql: String, vararg params: Any?, map: ResultSet.() -> T): List<T> =
    prepareStatement(sql).use { it.bind(params.toList()).executeQuery().list(map) }

fun <T> Connection.queryOne(sql: String, vararg params: Any?, map: ResultSet.() -> T): T? =
    query(sql, *params, map = map).firstOrNull()

fun Connection.update(sql: String, vararg params: Any?): Int =
    prepareStatement(sql).use { it.bind(params.toList()).executeUpdate() }

fun <T> ResultSet.list(map: ResultSet.() -> T): List<T> = buildList { while (next()) add(map()) }

fun ResultSet.doubleOrNull(column: Int): Double? = getDouble(column).takeUnless { wasNull() }
