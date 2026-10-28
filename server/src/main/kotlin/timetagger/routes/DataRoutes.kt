package timetagger.routes

import io.ktor.server.response.respond
import io.ktor.server.routing.Route
import io.ktor.server.routing.get
import io.ktor.server.routing.put
import io.ktor.server.routing.route
import timetagger.badRequest
import timetagger.db.RecordQuery
import timetagger.model.RecordsResponse
import timetagger.model.SettingsResponse
import timetagger.model.StatusResponse
import timetagger.service.SyncService

/** GET records?timerange=t1-t2[&running][&hidden][&tag=a,b], PUT records. */
fun Route.recordRoutes(sync: SyncService) = route("records") {
    get {
        val range = call.request.queryParameters["timerange"].orEmpty().trim()
        if (range.isEmpty()) badRequest("/records needs timerange (2 timestamps)")
        val bounds = range.split("-").map { it.toDoubleOrNull() }
        if (bounds.size != 2 || null in bounds) badRequest("/records timerange needs 2 numbers (timestamps)")
        val tags = call.request.queryParameters["tag"].orEmpty().replace("#", "").split(",").map { it.trim() }.filter { it.isNotEmpty() }
        val query = RecordQuery(bounds[0]!!.toLong(), bounds[1]!!.toLong(), tags, call.flag("running"), call.flag("hidden"))
        call.respond(RecordsResponse(sync.findRecords(call.user.username, query)))
    }
    put { call.respond(sync.pushRecords(call.user.username, call.receiveList("records"))) }
}

/** GET settings, PUT settings. */
fun Route.settingRoutes(sync: SyncService) = route("settings") {
    get { call.respond(SettingsResponse(sync.allSettings(call.user.username))) }
    put { call.respond(sync.pushSettings(call.user.username, call.receiveList("settings"))) }
}

/** GET updates?since=ts: everything changed since the client's last sync. PUT forcereset. */
fun Route.syncRoutes(sync: SyncService) {
    get("updates") {
        val raw = call.request.queryParameters["since"].orEmpty().trim()
        if (raw.isEmpty()) badRequest("/updates needs since")
        val since = raw.toDoubleOrNull() ?: badRequest("/updates since needs a number (timestamp)")
        call.respond(sync.updates(call.user.username, since))
    }
    put("forcereset") {
        sync.forceReset(call.user.username)
        call.respond(StatusResponse("ok"))
    }
}
