package timetagger

import io.zonky.test.db.postgres.embedded.EmbeddedPostgres
import kotlinx.coroutines.runBlocking
import timetagger.auth.PasswordService
import timetagger.db.Database
import timetagger.db.RecordFilter
import timetagger.db.RecordRepository
import timetagger.db.UserRepository
import timetagger.model.Record
import timetagger.model.RecordInput
import timetagger.service.MergeService
import timetagger.service.RecordService
import java.time.Instant
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals

/** The cases the old timetagger_merge.py script was tested with, plus the write itself. */
class MergeTest {
    private lateinit var pg: EmbeddedPostgres
    private lateinit var db: Database
    private lateinit var merge: MergeService
    private val t0 = Instant.parse("2026-10-28T08:00:00Z")

    @BeforeTest
    fun setUp() {
        pg = EmbeddedPostgres.start()
        db = Database("postgresql://postgres:postgres@localhost:${pg.port}/postgres")
        db.migrate()
        runBlocking { PasswordService(db, UserRepository()).set("alice", "secret") }
        merge = MergeService(db, RecordRepository())
    }

    @AfterTest
    fun tearDown() {
        db.close()
        pg.close()
    }

    /** A record [length] seconds long starting [start] seconds in; length 0 means running. */
    private fun rec(id: Long, start: Long, length: Long, ds: String = "waiting for a task") = Record(
        id = id, start = t0.plusSeconds(start), stop = if (length == 0L) null else t0.plusSeconds(start + length),
        description = ds, tags = emptyList(), deletedAt = null, revision = id,
    )

    private fun ids(recs: List<Record>) = merge.chains(recs).map { c -> c.records.map { it.id } }

    @Test
    fun chains() {
        assertEquals(listOf(listOf(1L, 2L)), ids(listOf(rec(1, 0, 70), rec(2, 70, 10))), "consecutive, same description")
        assertEquals(listOf(listOf(1L, 2L)), ids(listOf(rec(1, 0, 70), rec(2, 70, 10), rec(3, 80, 0))), "a running record ends the chain, which still stands")
        assertEquals(emptyList(), ids(listOf(rec(1, 0, 70), rec(2, 70, 0), rec(3, 70, 10))), "a running record in the middle doesn't glue across itself")
        assertEquals(emptyList(), ids(listOf(rec(1, 0, 70), rec(2, 200, 10))), "a gap over a minute")
        assertEquals(emptyList(), ids(listOf(rec(1, 0, 70), rec(2, 70, 10, "#sm-1061"), rec(3, 80, 10))), "something else in between")
        assertEquals(listOf(listOf(1L, 2L)), ids(listOf(rec(1, 0, 70), rec(2, 70, 10, "waiting for a task #finished"))), "#finished compares equal")
        assertEquals(listOf(listOf(1L, 2L, 3L)), ids(listOf(rec(1, 0, 70), rec(2, 70, 10), rec(3, 81, 10))), "three in a row")
    }

    @Test
    fun mergeKeepsTheFirstAndTheMarker() = runBlocking {
        val records = RecordService(db, RecordRepository())
        val alice = db.io { UserRepository().byName(it, "alice") }!!.id
        fun at(s: Long) = t0.plusSeconds(s)
        val a = records.create(alice, RecordInput(start = at(0), stop = at(3600), description = "#core-2517"))
        records.create(alice, RecordInput(start = at(3601), stop = at(5400), description = "#core-2517 #finished"))
        records.create(alice, RecordInput(start = at(9000), stop = at(9600), description = "#core-2517"))

        assertEquals(1, merge.mergeRecent(alice, now = at(10_000)))
        val live = db.io { RecordRepository().find(it, alice, RecordFilter(from = at(-1), to = at(20_000))) }
        assertEquals(listOf(a.id to "#core-2517 #finished", live[1].id to "#core-2517"), live.map { it.id to it.description })
        assertEquals(at(5400), live[0].stop)
        // Nothing left: a second round writes nothing.
        assertEquals(0, merge.mergeRecent(alice, now = at(10_000)))
    }
}
