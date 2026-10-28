package timetagger

import io.ktor.http.HttpStatusCode
import io.ktor.serialization.kotlinx.json.json
import io.ktor.server.application.Application
import io.ktor.server.application.install
import io.ktor.server.auth.Authentication
import io.ktor.server.auth.UserIdPrincipal
import io.ktor.server.auth.authenticate
import io.ktor.server.auth.basic
import io.ktor.server.auth.jwt.jwt
import io.ktor.http.auth.HttpAuthHeader
import io.ktor.server.plugins.contentnegotiation.ContentNegotiation
import io.ktor.server.plugins.statuspages.StatusPages
import io.ktor.server.request.httpMethod
import io.ktor.server.request.path
import io.ktor.server.response.respond
import io.ktor.server.response.respondText
import io.ktor.server.routing.get
import io.ktor.server.routing.route
import io.ktor.server.routing.routing
import kotlinx.serialization.json.Json
import timetagger.auth.JwtCodec
import timetagger.auth.PasswordService
import timetagger.auth.TokenService
import timetagger.config.Config
import timetagger.db.CredentialRepository
import timetagger.db.Database
import timetagger.db.RecordRepository
import timetagger.db.SettingRepository
import timetagger.db.UserInfoRepository
import timetagger.model.VersionResponse
import timetagger.routes.loginRoutes
import timetagger.routes.recordRoutes
import timetagger.routes.settingRoutes
import timetagger.routes.syncRoutes
import timetagger.routes.tokenRoutes
import timetagger.service.SyncService

/** Everything the routes need, wired once per application. */
class Services(val config: Config, db: Database) {
    private val userInfo = UserInfoRepository()
    val passwords = PasswordService(db, CredentialRepository())
    val jwt = JwtCodec(config.jwtKey)
    val tokens = TokenService(jwt, db, userInfo)
    val sync = SyncService(db, RecordRepository(), SettingRepository(), userInfo)
}

private const val LOGIN = "login"
private const val TOKEN = "token"

fun version(): String = Database.resource("version.txt").trim()

fun Application.module(config: Config, db: Database) {
    val services = Services(config, db)
    val api = "${config.pathPrefix}api/v2"

    install(ContentNegotiation) { json(Json { encodeDefaults = true; explicitNulls = true }) }
    install(Authentication) {
        basic(LOGIN) {
            realm = "TimeTagger"
            validate { c -> UserIdPrincipal(c.name.trim()).takeIf { services.passwords.verify(c.name, c.password) } }
        }
        jwt(TOKEN) {
            // Clients send the bare token in an "authtoken" header rather than "Authorization: Bearer".
            authHeader { call -> call.request.headers["authtoken"]?.takeIf { it.isNotBlank() }?.let { HttpAuthHeader.Single("Bearer", it.trim()) } }
            verifier(services.jwt.verifier)
            validate { services.tokens.validate(it.payload) }
            challenge { _, _ -> call.respondText("unauthorized: missing, invalid, expired or revoked authtoken", status = HttpStatusCode.Unauthorized) }
        }
    }
    install(StatusPages) {
        exception<ApiException> { call, e -> call.respondText(e.message.orEmpty(), status = e.status) }
        status(HttpStatusCode.NotFound) { call, _ ->
            val path = call.request.path()
            val message = if (path.startsWith("$api/")) "not found: /${path.removePrefix("$api/")} is not a valid API path"
            else "not found: only serving the API at $api/"
            call.respondText(message, status = HttpStatusCode.NotFound)
        }
        status(HttpStatusCode.MethodNotAllowed) { call, _ ->
            val path = call.request.path().removePrefix("$api/")
            call.respondText("method not allowed: /$path does not take ${call.request.httpMethod.value}", status = HttpStatusCode.MethodNotAllowed)
        }
    }

    routing {
        get("${config.pathPrefix}status") { call.respondText("ok") }
        route(api) {
            get { call.respondText("TimeTagger API v2") }
            authenticate(LOGIN) { loginRoutes(services.tokens) }
            authenticate(TOKEN) {
                get("version") { call.respond(VersionResponse(version())) }
                tokenRoutes(services.tokens)
                recordRoutes(services.sync)
                settingRoutes(services.sync)
                syncRoutes(services.sync)
            }
        }
    }
}
