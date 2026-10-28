package timetagger.routes

import io.ktor.http.HttpStatusCode
import io.ktor.server.auth.UserIdPrincipal
import io.ktor.server.auth.principal
import io.ktor.server.response.respond
import io.ktor.server.routing.Route
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import timetagger.ApiException
import timetagger.auth.TokenKind
import timetagger.auth.TokenService
import timetagger.model.TokenResponse

/** POST login with HTTP Basic credentials (checked by the "login" provider) → a web token. */
fun Route.loginRoutes(tokens: TokenService) {
    post("login") {
        call.respond(TokenResponse(tokens.issue(call.principal<UserIdPrincipal>()!!.name, TokenKind.WEB)))
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
