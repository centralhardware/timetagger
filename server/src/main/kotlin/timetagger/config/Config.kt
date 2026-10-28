package timetagger.config

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
                pathPrefix = value("path_prefix")?.let { toPathPrefix(it) } ?: d.pathPrefix,
            )
        }

        fun toPathPrefix(s: String): String {
            var p = s.trim()
            if (!p.startsWith("/")) p = "/$p"
            if (!p.endsWith("/") && p != "/") p = "$p/"
            return p
        }
    }
}
