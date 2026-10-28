package timetagger.routes

import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.server.request.path
import io.ktor.server.response.header
import io.ktor.server.request.receive
import io.ktor.server.response.respond
import io.ktor.server.routing.Route
import io.ktor.server.routing.delete
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.put
import io.ktor.server.routing.route
import io.ktor.server.sse.sse
import io.ktor.sse.ServerSentEvent
import io.ktor.utils.io.ClosedWriteChannelException
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.merge
import timetagger.Invalid
import timetagger.db.RecordFilter
import timetagger.model.RecordBatch
import timetagger.model.RecordInput
import timetagger.model.RecordList
import timetagger.model.SettingInput
import timetagger.model.SettingList
import timetagger.model.TagList
import timetagger.service.RecordService
import timetagger.service.SettingService
import timetagger.service.SyncService
import java.time.Instant
import kotlin.time.Duration.Companion.seconds
import org.slf4j.LoggerFactory

private val log = LoggerFactory.getLogger("timetagger.sync")

/**
 * GET /records?from&to[&tag=a&tag=b][&running][&deleted][&q=text] (with q, from and to are optional);
 * POST /records creates one, stopping any running record if it is itself running;
 * GET, PUT and DELETE /records/{id}; POST /records/batch writes several in one transaction;
 * GET /records/tags lists the tags in use, most recent first (for autocomplete).
 */
fun Route.recordRoutes(records: RecordService) = route("records") {
    get {
        val q = call.request.queryParameters["q"]?.trim()?.takeIf { it.isNotEmpty() }
        val filter = RecordFilter(
            // A search may span all time; a plain listing needs its range.
            from = call.instantParam("from") ?: if (q != null) Instant.EPOCH else throw Invalid("from is required"),
            to = call.instantParam("to") ?: if (q != null) Instant.parse("9999-12-31T00:00:00Z") else throw Invalid("to is required"),
            tags = call.request.queryParameters.getAll("tag").orEmpty().filter { it.isNotBlank() },
            running = call.boolParam("running"),
            deleted = call.boolParam("deleted") ?: false,
            text = q,
        )
        call.respond(RecordList(records.find(call.auth.userId, filter)))
    }
    post {
        val created = records.create(call.auth.userId, call.receive<RecordInput>())
        call.response.header(HttpHeaders.Location, "${call.request.path()}/${created.id}")
        call.respond(HttpStatusCode.Created, created)
    }
    get("tags") { call.respond(TagList(records.tags(call.auth.userId))) }
    post("batch") { call.respond(RecordList(records.saveAll(call.auth.userId, call.receive<RecordBatch>().records))) }
    route("{id}") {
        get { call.respond(records.get(call.auth.userId, call.path("id"))) }
        put { call.respond(records.update(call.auth.userId, call.path("id"), call.receive<RecordInput>())) }
        delete {
            records.delete(call.auth.userId, call.path("id"))
            call.respond(HttpStatusCode.NoContent)
        }
    }
}

/** GET /settings; GET and PUT /settings/{key}. */
fun Route.settingRoutes(settings: SettingService) = route("settings") {
    get { call.respond(SettingList(settings.all(call.auth.userId))) }
    route("{key}") {
        get { call.respond(settings.get(call.auth.userId, call.path("key"))) }
        put { call.respond(settings.put(call.auth.userId, call.path("key"), call.receive<SettingInput>())) }
    }
}

/**
 * GET /changes?since=<revision>: everything written after that revision (0 for everything).
 * GET /changes/stream: server-sent events, a `change` event after each write, for a client to fetch /changes.
 */
fun Route.syncRoutes(sync: SyncService) {
    sse("changes/stream") {
        val user = call.auth.username
        log.info("Change stream opened for {}", user)
        // The heartbeat goes through the same loop as the events (Ktor's own heartbeat runs in a
        // separate job, which logs a client going away as an error), so a closed connection ends here.
        val heartbeat = flow { while (true) { delay(30.seconds); emit(ServerSentEvent(comments = "heartbeat")) } }
        try {
            merge(sync.written(call.auth.userId).map { ServerSentEvent(event = "change", data = "") }, heartbeat).collect { send(it) }
        } catch (_: ClosedWriteChannelException) {
            // The client went away.
        } finally {
            log.info("Change stream closed for {}", user)
        }
    }
    get("changes") {
        val since = call.request.queryParameters["since"]?.let { it.toLongOrNull() ?: throw Invalid("since must be a revision number") } ?: 0
        call.respond(sync.changes(call.auth.userId, since))
    }
}
