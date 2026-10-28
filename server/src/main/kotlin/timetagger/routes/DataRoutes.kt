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
import io.ktor.server.sse.heartbeat
import io.ktor.server.sse.sse
import io.ktor.sse.ServerSentEvent
import timetagger.Invalid
import timetagger.db.RecordFilter
import timetagger.model.RecordBatch
import timetagger.model.RecordInput
import timetagger.model.RecordList
import timetagger.model.SettingInput
import timetagger.model.SettingList
import timetagger.service.RecordService
import timetagger.service.SettingService
import timetagger.service.SyncService
import kotlin.time.Duration.Companion.seconds

/**
 * GET /records?from&to[&tag=a&tag=b][&running][&deleted]; POST /records creates one;
 * GET, PUT and DELETE /records/{id}; POST /records/batch writes several in one transaction.
 */
fun Route.recordRoutes(records: RecordService) = route("records") {
    get {
        val filter = RecordFilter(
            from = call.instantParam("from") ?: throw Invalid("from is required"),
            to = call.instantParam("to") ?: throw Invalid("to is required"),
            tags = call.request.queryParameters.getAll("tag").orEmpty().filter { it.isNotBlank() },
            running = call.boolParam("running"),
            deleted = call.boolParam("deleted") ?: false,
        )
        call.respond(RecordList(records.find(call.auth.userId, filter)))
    }
    post {
        val created = records.create(call.auth.userId, call.receive<RecordInput>())
        call.response.header(HttpHeaders.Location, "${call.request.path()}/${created.id}")
        call.respond(HttpStatusCode.Created, created)
    }
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
        heartbeat { period = 30.seconds }
        sync.written(call.auth.userId).collect { send(ServerSentEvent(event = "change", data = "")) }
    }
    get("changes") {
        val since = call.request.queryParameters["since"]?.let { it.toLongOrNull() ?: throw Invalid("since must be a revision number") } ?: 0
        call.respond(sync.changes(call.auth.userId, since))
    }
}
