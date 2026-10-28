package timetagger.routes

import io.ktor.http.HttpStatusCode
import io.ktor.server.plugins.origin
import io.ktor.server.request.receiveText
import io.ktor.server.response.respond
import io.ktor.server.routing.Route
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import kotlinx.serialization.json.Json
import timetagger.ApiException
import timetagger.auth.LoginOrigin
import timetagger.auth.LoginRequest
import timetagger.auth.LoginService
import timetagger.auth.TokenKind
import timetagger.auth.TokenService
import timetagger.badRequest
import timetagger.model.TokenResponse
import java.util.Base64

private val lenient = Json { ignoreUnknownKeys = true }

/** POST bootstrap_authentication: trades a login for a web token. Needs no token itself. */
fun Route.loginRoutes(login: LoginService, proxyHeader: String) {
    post("bootstrap_authentication") {
        val req = runCatching {
            lenient.decodeFromString<LoginRequest>(String(Base64.getDecoder().decode(call.receiveText().trim())))
        }.getOrElse { badRequest("invalid authentication payload") }
        val origin = LoginOrigin(
            serverHost = call.request.local.serverHost,
            remoteAddress = call.request.origin.remoteAddress,
            proxyUser = call.request.headers[proxyHeader].orEmpty().trim(),
        )
        call.respond(TokenResponse(login.login(req, origin)))
    }
}

/** GET webtoken / apitoken: fresh tokens, minted only with a web token. `?reset=1` revokes older ones. */
fun Route.tokenRoutes(tokens: TokenService) {
    for (kind in TokenKind.entries) {
        get(kind.id) {
            if (call.user.isApiToken) throw ApiException(HttpStatusCode.Forbidden, "forbidden: /${kind.id} needs auth with a web-token")
            call.respond(TokenResponse(tokens.issue(call.user.username, kind, reset = call.flag("reset") == true)))
        }
    }
}
