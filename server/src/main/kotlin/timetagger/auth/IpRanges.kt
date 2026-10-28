package timetagger.auth

import java.net.InetAddress

/** IPv4/IPv6 ranges like "10.99.0.0/24", "192.168/16" or a single address. */
class IpRanges(spec: String) {
    private val ranges = spec.replace(";", ",").split(",").map { it.trim() }.filter { it.isNotEmpty() }.map(::parse)

    fun contains(ip: String): Boolean {
        val addr = runCatching { InetAddress.getByName(ip).address }.getOrNull() ?: return false
        return ranges.any { (net, bits) -> net.size == addr.size && matches(net, addr, bits) }
    }

    private fun parse(s: String): Pair<ByteArray, Int> {
        val host = s.substringBefore("/")
        // Short IPv4 forms like "192.168" are padded with zeros, as in Python's iptools.
        val dots = host.count { it == '.' }
        val full = if (":" !in host && dots < 3) (host.split(".") + List(3 - dots) { "0" }).joinToString(".") else host
        val addr = InetAddress.getByName(full).address
        val bits = if ("/" in s) s.substringAfter("/").toInt() else addr.size * 8
        return addr to bits
    }

    private fun matches(net: ByteArray, addr: ByteArray, bits: Int): Boolean {
        for (i in net.indices) {
            val take = (bits - i * 8).coerceIn(0, 8)
            if (take == 0) return true
            val mask = (0xFF shl (8 - take)) and 0xFF
            if ((net[i].toInt() and mask) != (addr[i].toInt() and mask)) return false
        }
        return true
    }
}
