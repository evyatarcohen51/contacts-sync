package com.dvirchi.contactsync.receiver

import java.net.Inet4Address
import java.net.NetworkInterface

object Net {
    data class Addresses(val tailscale: String?, val lan: List<String>)

    /** Tailscale uses the 100.64.0.0/10 (CGNAT) range for device addresses. */
    private fun isTailscale(a: Inet4Address): Boolean {
        val b = a.address
        return (b[0].toInt() and 0xff) == 100 && (b[1].toInt() and 0xff) in 64..127
    }

    /** Android VPN apps (Tailscale included) always get a "tunN" interface. */
    private fun isVpn(name: String) = name.startsWith("tun") || name.startsWith("tailscale")

    /** Mobile-data interfaces: carriers also hand out 100.64/10 and 10/8 addresses there. */
    private fun isCellular(name: String) =
        listOf("rmnet", "ccmni", "pdp", "wwan", "v4-", "clat", "radio").any { name.startsWith(it) }

    private fun lanRank(name: String) = when {
        name.startsWith("wlan") -> 0
        name.startsWith("eth") -> 1
        else -> 2
    }

    fun addresses(): Addresses {
        var ts: String? = null
        val lan = ArrayList<Pair<Int, String>>()
        runCatching {
            for (ni in NetworkInterface.getNetworkInterfaces()) {
                if (!ni.isUp || ni.isLoopback) continue
                val name = ni.name.lowercase()
                for (addr in ni.inetAddresses) {
                    if (addr !is Inet4Address || addr.isLoopbackAddress) continue
                    val host = addr.hostAddress ?: continue
                    when {
                        isVpn(name) -> if (isTailscale(addr)) ts = host
                        isCellular(name) -> Unit
                        addr.isSiteLocalAddress -> lan += lanRank(name) to host
                    }
                }
            }
        }
        return Addresses(ts, lan.sortedBy { it.first }.map { it.second })
    }
}
