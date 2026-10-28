package timetagger

/**
 * Server configuration, read from `TIMETAGGER_*` environment variables
 * (or `--name=value` / `--name value` arguments, which win).
 */
data class Config(
    /** Address and port to bind on. */
    val bind: String = "127.0.0.1:8080",
    /** PostgreSQL connection string, e.g. postgresql://user:pass@host:5432/timetagger. Required. */
    val dbUri: String = "",
    /** Secret for signing tokens. Empty means an ephemeral key: sessions end on restart. */
    val jwtKey: String = "",
    val logLevel: String = "info",
    /** Accept the username from a trusted reverse proxy header (e.g. Authelia). */
    val proxyAuthEnabled: Boolean = false,
    /** Trusted proxy IPs, with or without CIDR: "127.0.0.1,10.99.0.0/24,192.168/16". */
    val proxyAuthTrusted: String = "127.0.0.1",
    val proxyAuthHeader: String = "X-Remote-User",
    /** Path prefix the API is served under; always starts and ends with '/'. */
    val pathPrefix: String = "/timetagger/",
) {
    val host: String get() = bind.substringBeforeLast(":")
    val port: Int get() = bind.substringAfterLast(":").toInt()

    companion object {
        fun load(args: List<String> = emptyList(), env: Map<String, String> = System.getenv()): Config {
            fun value(name: String): String? {
                val dashed = name.replace("_", "-")
                for ((i, arg) in args.withIndex()) {
                    for (n in listOf(name, dashed)) {
                        if (arg.startsWith("--$n=")) return arg.substringAfter("=")
                        if (arg == "--$n" && i + 1 < args.size) return args[i + 1]
                    }
                }
                return env["TIMETAGGER_" + name.uppercase()]
            }
            val d = Config()
            return Config(
                bind = value("bind") ?: d.bind,
                dbUri = value("db_uri") ?: d.dbUri,
                jwtKey = value("jwt_key") ?: d.jwtKey,
                logLevel = value("log_level") ?: d.logLevel,
                proxyAuthEnabled = value("proxy_auth_enabled")?.let { toBool(it) } ?: d.proxyAuthEnabled,
                proxyAuthTrusted = value("proxy_auth_trusted") ?: d.proxyAuthTrusted,
                proxyAuthHeader = value("proxy_auth_header") ?: d.proxyAuthHeader,
                pathPrefix = value("path_prefix")?.let { toPathPrefix(it) } ?: d.pathPrefix,
            )
        }

        fun toBool(s: String) = s.lowercase() in setOf("true", "yes", "on", "1")

        fun toPathPrefix(s: String): String {
            var p = s.trim()
            if (!p.startsWith("/")) p = "/$p"
            if (!p.endsWith("/") && p != "/") p = "$p/"
            return p
        }
    }
}
