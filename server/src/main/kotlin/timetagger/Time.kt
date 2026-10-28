package timetagger

/** Unix time in seconds, with fractions, as the API uses it. */
fun now(): Double = System.currentTimeMillis() / 1000.0
