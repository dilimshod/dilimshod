package uz.roadvis.app.roaddata

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import uz.roadvis.app.l10n.L
import uz.roadvis.core.OSMElement
import uz.roadvis.core.OverpassError
import uz.roadvis.core.OverpassQuery
import java.net.URI
import kotlin.math.max
import kotlin.math.min

/** Errors of [OverpassClient] (port of iOS `OverpassClientError`). */
sealed class OverpassClientError(message: String) : Exception(message) {
    class RateLimited(val retryAfterSeconds: Double) :
        OverpassClientError(L("overpass.rateLimited", max(1, kotlin.math.ceil(retryAfterSeconds).toInt())))
    class BadQuery(detail: String) :
        OverpassClientError(if (detail.isEmpty()) L("overpass.rejected") else L("overpass.rejectedWith", detail))
    class Offline : OverpassClientError(L("net.noInternet"))
    class AllEndpointsFailed(reasons: List<String>) :
        OverpassClientError(if (reasons.isEmpty()) L("overpass.allFailed") else L("overpass.allFailed") + " — " + reasons.joinToString("; "))
    class NoValidEndpoint : OverpassClientError(L("overpass.noEndpoint"))
}

/**
 * Overpass API client: requests are serialized (one at a time, polite to the free public servers), tried on the
 * configured endpoint first and then on the [fallbacks] mirrors; HTTP 429 / 406 put a server on a cooldown
 * (Retry-After, default 30 s). Complete answers are cached for 10 minutes (≤ 50 queries).
 */
class OverpassClient(primaryEndpoint: String, fallbacks: List<String>) {
    companion object {
        const val REQUEST_TIMEOUT_MS = 25_000
        const val ROUTE_QUERY_TIMEOUT_MS = 45_000
        const val RATE_LIMIT_COOLDOWN_S = 30.0
        const val CACHE_TTL_MS = 10 * 60 * 1000L
        const val CACHE_CAPACITY = 50

        fun normalized(endpoint: String): String = endpoint.trim().trimEnd('/')
    }

    @Volatile private var primary = normalized(primaryEndpoint)
    private val fallbackEndpoints = fallbacks.map(::normalized)
    private val queue = Mutex()
    private val cooldownUntil = HashMap<String, Long>()
    private val cache = LinkedHashMap<String, Pair<List<OSMElement>, Long>>()

    fun setPrimaryEndpoint(endpoint: String) { primary = normalized(endpoint) }

    private sealed class Outcome {
        class Complete(val elements: List<OSMElement>) : Outcome()
        class Partial(val elements: List<OSMElement>, val remark: String) : Outcome()
        class Failed(val reason: String) : Outcome()
        class RateLimited(val reason: String) : Outcome()
        class Rejected(val message: String) : Outcome()
    }

    suspend fun run(query: String, timeoutMs: Int = REQUEST_TIMEOUT_MS): List<OSMElement> {
        cached(query)?.let { return it }
        return queue.withLock {
            cached(query) ?: fetchWithFallback(query, timeoutMs)
        }
    }

    @Synchronized private fun cached(query: String): List<OSMElement>? {
        val entry = cache[query] ?: return null
        if (System.currentTimeMillis() - entry.second >= CACHE_TTL_MS) { cache.remove(query); return null }
        return entry.first
    }

    @Synchronized private fun store(query: String, elements: List<OSMElement>) {
        val now = System.currentTimeMillis()
        cache.entries.removeAll { now - it.value.second >= CACHE_TTL_MS }
        cache[query] = elements to now
        while (cache.size > CACHE_CAPACITY) cache.remove(cache.keys.first())
    }

    private fun orderedEndpoints(): List<String> {
        val seen = HashSet<String>()
        return (listOf(primary) + fallbackEndpoints).filter { it.isNotEmpty() && seen.add(it.lowercase()) }
    }

    private suspend fun fetchWithFallback(query: String, timeoutMs: Int): List<OSMElement> {
        val endpoints = orderedEndpoints()
        if (endpoints.isEmpty()) throw OverpassClientError.NoValidEndpoint()
        val now = System.currentTimeMillis()
        val available = endpoints.filter { (cooldownUntil[it] ?: 0L) <= now }
        if (available.isEmpty()) {
            val soonest = endpoints.mapNotNull { cooldownUntil[it] }.minOrNull()
            val wait = soonest?.let { (it - now) / 1000.0 } ?: RATE_LIMIT_COOLDOWN_S
            throw OverpassClientError.RateLimited(max(1.0, wait))
        }
        val body = OverpassQuery.formBody(query)
        val reasons = ArrayList<String>()
        var rejection: String? = null
        var emptyPartial = false
        var rateLimitedCount = 0
        var offlineCount = 0
        var timeouts = 0
        for (endpoint in available) {
            val host = hostName(endpoint)
            val valid = try {
                val uri = URI(endpoint)
                (uri.scheme == "https" || uri.scheme == "http") && uri.host != null
            } catch (_: Exception) { false }
            if (!valid) { reasons.add("$host: " + L("overpass.badAddress")); continue }
            val outcome = try {
                attempt(endpoint, body, timeoutMs)
            } catch (e: Http.NetworkException) {
                if (e.kind == Http.NetworkException.Kind.HOST_NOT_FOUND) offlineCount += 1
                if (e.kind == Http.NetworkException.Kind.TIMEOUT) {
                    timeouts += 1
                    // One overloaded server timing out is what the fallback list is for; two is a stalled link.
                    if (timeouts >= 2) {
                        reasons.add("$host: " + (e.message ?: L("net.timedOut")))
                        throw OverpassClientError.AllEndpointsFailed(reasons)
                    }
                }
                Outcome.Failed(e.message ?: L("net.loadError"))
            }
            when (outcome) {
                is Outcome.Complete -> { store(query, outcome.elements); return outcome.elements }
                is Outcome.Partial -> {
                    if (outcome.elements.isNotEmpty()) return outcome.elements
                    emptyPartial = true
                    reasons.add("$host: ${shortened(outcome.remark)}")
                }
                is Outcome.Failed -> reasons.add("$host: ${outcome.reason}")
                is Outcome.RateLimited -> { rateLimitedCount += 1; reasons.add("$host: ${outcome.reason}") }
                is Outcome.Rejected -> { rejection = outcome.message; reasons.add("$host: " + L("overpass.requestRejected")) }
            }
        }
        // Every host failed DNS resolution: almost certainly no connectivity.
        if (offlineCount == available.size) throw OverpassClientError.Offline()
        rejection?.let { if (!emptyPartial) throw OverpassClientError.BadQuery(it) }
        if (rateLimitedCount == available.size) {
            val soonest = endpoints.mapNotNull { cooldownUntil[it] }.minOrNull()
            val wait = soonest?.let { (it - System.currentTimeMillis()) / 1000.0 } ?: RATE_LIMIT_COOLDOWN_S
            throw OverpassClientError.RateLimited(max(1.0, wait))
        }
        throw OverpassClientError.AllEndpointsFailed(reasons)
    }

    private suspend fun attempt(endpoint: String, body: ByteArray, timeoutMs: Int): Outcome {
        val response = try {
            Http.post(endpoint, body, "application/x-www-form-urlencoded", timeoutMs = max(5_000, timeoutMs))
        } catch (e: CancellationException) {
            throw e
        }
        return when (response.status) {
            200 -> {
                val data = response.body
                if (looksLikeHTML(data)) {
                    return Outcome.Failed(L("overpass.errorPage", shortened(OverpassQuery.htmlErrorMessage(data))))
                }
                val decoded = try {
                    OverpassQuery.decodeResponse(data)
                } catch (e: OverpassError) {
                    return Outcome.Failed(L("overpass.unparsable"))
                } catch (e: Exception) {
                    return Outcome.Failed(L("overpass.unparsable"))
                }
                val remark = decoded.remark?.trim()
                if (!remark.isNullOrEmpty()) Outcome.Partial(decoded.elements, remark) else Outcome.Complete(decoded.elements)
            }
            429, 406 -> {
                val wait = response.header("Retry-After")?.trim()?.toDoubleOrNull()?.let { min(300.0, max(5.0, it)) }
                    ?: RATE_LIMIT_COOLDOWN_S
                synchronized(cooldownUntil) { cooldownUntil[endpoint] = System.currentTimeMillis() + (wait * 1000).toLong() }
                Outcome.RateLimited(L("overpass.tooMany", response.status))
            }
            400 -> Outcome.Rejected(shortened(OverpassQuery.htmlErrorMessage(response.body)))
            502, 503, 504 -> Outcome.Failed(L("overpass.overloaded", response.status))
            else -> Outcome.Failed("HTTP ${response.status}")
        }
    }

    private fun hostName(endpoint: String): String =
        try { URI(endpoint).host } catch (_: Exception) { null } ?: (if (endpoint.isEmpty()) L("overpass.empty") else endpoint)

    private fun looksLikeHTML(data: ByteArray): Boolean {
        for (i in 0 until min(256, data.size)) {
            when (val b = data[i].toInt() and 0xFF) {
                0x20, 0x09, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF -> continue
                else -> return b == '<'.code
            }
        }
        return false
    }

    private fun shortened(text: String, limit: Int = 160): String =
        if (text.length <= limit) text else text.take(limit) + "…"
}
