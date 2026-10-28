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
import io.ktor.server.auth.UserIdPrincipal
import io.ktor.server.auth.authenticate
import io.ktor.server.auth.basic
import io.ktor.server.auth.jwt.jwt
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
import timetagger.auth.JwtCodec
import timetagger.auth.PasswordService
import timetagger.auth.TokenService
import timetagger.config.Config
import timetagger.db.Database
import timetagger.db.RecordRepository
import timetagger.db.SettingRepository
import timetagger.db.UserRepository
import timetagger.model.ApiJson
import timetagger.model.ErrorResponse
import timetagger.model.VersionResponse
import timetagger.routes.recordRoutes
import timetagger.routes.sessionRoutes
import timetagger.routes.settingRoutes
import timetagger.routes.syncRoutes
import timetagger.routes.tokenRoutes
import timetagger.service.RecordService
import timetagger.service.SettingService
import timetagger.service.SyncService
import timetagger.service.MergeService
import java.time.Duration

private val log = LoggerFactory.getLogger("timetagger.api")

private const val LOGIN = "login"
private const val TOKEN = "token"

/** Everything the routes need, wired once per application. */
class Services(db: Database, config: Config) {
    private val users = UserRepository()
    private val recordRepo = RecordRepository()
    private val settingRepo = SettingRepository()
    val passwords = PasswordService(db, users)
    val jwt = JwtCodec(config.jwtKey)
    val tokens = TokenService(jwt, db, users)
    val records = RecordService(db, recordRepo)
    val settings = SettingService(db, settingRepo)
    val sync = SyncService(db, recordRepo, settingRepo)
    val merge = MergeService(db, recordRepo, Duration.ofSeconds(config.mergeGapSeconds), config.mergeIgnoreTag.ifBlank { null })
}

fun version(): String = Database.resource("version.txt").trim()

private suspend fun ApplicationCall.error(status: HttpStatusCode, code: String, message: String) =
    respond(status, ErrorResponse(code, message))

fun Application.module(config: Config, db: Database) {
    val services = Services(db, config)
    if (config.autoMerge) services.merge.start(this)

    install(ContentNegotiation) { json(ApiJson) }
    install(SSE)
    // One line per request: method, path, status, user and time taken; the health check stays quiet.
    install(CallLogging) {
        level = Level.INFO
        logger = LoggerFactory.getLogger("timetagger.http")
        filter { !it.request.path().endsWith("/status") }
        format { call ->
            val user = call.principal<AuthInfo>()?.username ?: call.principal<UserIdPrincipal>()?.name ?: "-"
            "${call.request.httpMethod.value} ${call.request.path()} ${call.response.status()?.value ?: "-"} $user ${call.processingTimeMillis()}ms"
        }
    }
    install(Authentication) {
        basic(LOGIN) {
            realm = "TimeTagger"
            validate { c -> UserIdPrincipal(c.name.trim()).takeIf { services.passwords.verify(c.name, c.password) } }
        }
        jwt(TOKEN) {
            verifier(services.jwt.verifier)
            validate { services.tokens.validate(it.payload) }
            challenge { _, _ -> call.error(HttpStatusCode.Unauthorized, "unauthorized", "missing, invalid, expired or revoked bearer token") }
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
            log.error("Unhandled error on {} {}", call.request.httpMethod.value, call.request.path(), e)
            call.error(HttpStatusCode.InternalServerError, "internal", "internal server error")
        }
        status(HttpStatusCode.NotFound) { call, _ -> call.error(HttpStatusCode.NotFound, "not_found", "no such endpoint: ${call.request.path()}") }
        status(HttpStatusCode.MethodNotAllowed) { call, _ ->
            call.error(HttpStatusCode.MethodNotAllowed, "method_not_allowed", "${call.request.httpMethod.value} is not allowed on ${call.request.path()}")
        }
    }

    routing {
        // At the root, so the bare domain is the base URL, and under the prefix for clients set up with it.
        for (prefix in setOf("/", config.pathPrefix)) route(prefix) { api(services) }
    }
}

private fun Route.api(services: Services) {
    get("status") { call.respondText("ok") }
    route("api/v1") {
        get("version") { call.respond(VersionResponse(version())) }
        authenticate(LOGIN) { sessionRoutes(services.tokens) }
        authenticate(TOKEN) {
            tokenRoutes(services.tokens)
            recordRoutes(services.records)
            settingRoutes(services.settings)
            syncRoutes(services.sync)
        }
    }
}
