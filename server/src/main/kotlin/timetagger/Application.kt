package timetagger

import io.ktor.http.HttpStatusCode
import io.ktor.serialization.kotlinx.json.json
import io.ktor.server.application.Application
import io.ktor.server.application.ApplicationCall
import io.ktor.server.application.install
import io.ktor.server.sse.SSE
import io.ktor.server.plugins.calllogging.CallLogging
import io.ktor.server.plugins.calllogging.processingTimeMillis
import io.ktor.server.auth.principal
import timetagger.auth.AuthInfo
import org.slf4j.event.Level
import io.ktor.server.auth.Authentication
import io.ktor.server.auth.authenticate
import io.ktor.server.plugins.BadRequestException
import io.ktor.server.plugins.contentnegotiation.ContentNegotiation
import io.ktor.server.plugins.statuspages.StatusPages
import io.ktor.server.request.httpMethod
import io.ktor.server.request.path
import io.ktor.server.response.respond
import io.ktor.server.response.respondText
import io.ktor.server.routing.get
import io.ktor.server.routing.Route
import io.ktor.server.routing.route
import io.ktor.server.routing.routing
import org.slf4j.LoggerFactory
import kotlin.coroutines.cancellation.CancellationException
import timetagger.auth.AuthService
import timetagger.routes.accountRoutes
import timetagger.routes.authRoutes
import io.ktor.server.auth.bearer
import timetagger.config.Config
import timetagger.db.Database
import timetagger.model.ApiJson
import timetagger.model.ErrorResponse
import timetagger.model.VersionResponse
import timetagger.routes.recordRoutes
import timetagger.routes.settingRoutes
import timetagger.routes.workspaceRoutes
import timetagger.routes.syncRoutes
import timetagger.service.RecordService
import timetagger.service.SettingService
import timetagger.service.WorkspaceService
import timetagger.service.SyncService
import timetagger.service.MergeService
import io.ktor.server.plugins.di.dependencies
import io.ktor.server.routing.application

private val log = LoggerFactory.getLogger("timetagger.api")

private const val BEARER = "bearer"

fun version(): String = Database.resource("version.txt").trim()

private suspend fun ApplicationCall.error(status: HttpStatusCode, code: String, message: String) =
    respond(status, ErrorResponse(code, message))

fun Application.module(config: Config, db: Database) {
    registerDependencies(config, db)
    val auth: AuthService by dependencies
    if (config.autoMerge) {
        val merge: MergeService by dependencies
        merge.start(this)
    }

    install(ContentNegotiation) { json(ApiJson) }
    install(SSE)
    // One line per request: method, path, status, user and time taken; the health check stays quiet.
    install(CallLogging) {
        level = Level.INFO
        logger = LoggerFactory.getLogger("timetagger.http")
        filter { !it.request.path().endsWith("/status") }
        format { call ->
            val user = call.principal<AuthInfo>()?.username ?: "-"
            "${call.request.httpMethod.value} ${call.request.path()} ${call.response.status()?.value ?: "-"} $user ${call.processingTimeMillis()}ms"
        }
    }
    install(Authentication) {
        bearer(BEARER) {
            authenticate { auth.authenticate(it.token) }
        }
    }
    install(StatusPages) {
        exception<Conflict> { call, e ->
            log.info("Conflict on record {}: the client's revision is stale, stored is {}", e.current.id, e.current.revision)
            call.respond(e.status, ErrorResponse(e.code, e.message.orEmpty(), e.current))
        }
        exception<ApiException> { call, e -> call.error(e.status, e.code, e.message.orEmpty()) }
        // A body that is not the expected JSON.
        exception<BadRequestException> { call, e ->
            call.error(HttpStatusCode.UnprocessableEntity, "invalid", e.cause?.message ?: e.message.orEmpty())
        }
        exception<Throwable> { call, e ->
            // A request cancelled because its client left is not an error.
            if (e is CancellationException) throw e
            log.error("Unhandled error on {} {}", call.request.httpMethod.value, call.request.path(), e)
            call.error(HttpStatusCode.InternalServerError, "internal", "internal server error")
        }
        // The bearer provider answers a missing or bad credential with a bare 401.
        status(HttpStatusCode.Unauthorized) { call, _ ->
            call.error(HttpStatusCode.Unauthorized, "unauthorized", "missing, invalid or expired access token or API key")
        }
        status(HttpStatusCode.NotFound) { call, _ -> call.error(HttpStatusCode.NotFound, "not_found", "no such endpoint: ${call.request.path()}") }
        status(HttpStatusCode.MethodNotAllowed) { call, _ ->
            call.error(HttpStatusCode.MethodNotAllowed, "method_not_allowed", "${call.request.httpMethod.value} is not allowed on ${call.request.path()}")
        }
    }

    routing {
        // At the root, so the bare domain is the base URL, and under the prefix for clients set up with it.
        for (prefix in setOf("/", config.pathPrefix)) route(prefix) { api() }
    }
}

private fun Route.api() {
    val auth: AuthService by application.dependencies
    val records: RecordService by application.dependencies
    val settings: SettingService by application.dependencies
    val workspaces: WorkspaceService by application.dependencies
    val sync: SyncService by application.dependencies
    get("status") { call.respondText("ok") }
    route("api/v1") {
        get("version") { call.respond(VersionResponse(version())) }
        authRoutes(auth)
        authenticate(BEARER) {
            accountRoutes(auth)
            recordRoutes(records)
            settingRoutes(settings)
            workspaceRoutes(workspaces)
            syncRoutes(sync)
        }
    }
}
