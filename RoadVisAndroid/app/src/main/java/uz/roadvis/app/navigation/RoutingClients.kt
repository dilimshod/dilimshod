package uz.roadvis.app.navigation

import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import uz.roadvis.app.l10n.L
import uz.roadvis.app.roaddata.Http
import uz.roadvis.core.GeoPoint
import uz.roadvis.core.NavRoute
import uz.roadvis.core.OSRM
import uz.roadvis.core.OSRMError
import uz.roadvis.core.RVLang
import uz.roadvis.core.RouteEdgeAttributes
import uz.roadvis.core.Valhalla
import uz.roadvis.core.ValhallaError
import java.net.URI

/** Serializes requests to one server and keeps ≥ [spacingMs] between their starts (FOSSGIS: ≤ 1 request/s). */
class RequestSpacer(private val spacingMs: Long = 1_100) {
    private val mutex = Mutex()
    private var nextAllowed = 0L

    suspend fun <T> run(block: suspend () -> T): T = mutex.withLock {
        val wait = nextAllowed - System.currentTimeMillis()
        if (wait > 0) delay(wait)
        try { block() } finally { nextAllowed = System.currentTimeMillis() + spacingMs }
    }
}

/** Localized routing-engine error (iOS `ValhallaClientError` / `OSRMClientError`). */
class RoutingException(message: String) : Exception(message)

/** Valhalla `/route` (with alternates) and `/trace_attributes` (port of iOS `ValhallaClient`). */
class ValhallaClient(endpoint: String) {
    @Volatile var endpoint: String = normalized(endpoint)
        set(value) { field = normalized(value) }
    private val spacer = RequestSpacer()

    companion object {
        const val TIMEOUT_MS = 25_000
        fun normalized(e: String) = e.trim().trimEnd('/')
        fun url(endpoint: String, path: String): String? {
            val base = normalized(endpoint)
            if (base.isEmpty()) return null
            return try {
                val uri = URI("$base/$path")
                if ((uri.scheme == "https" || uri.scheme == "http") && uri.host != null) "$base/$path" else null
            } catch (_: Exception) { null }
        }
    }

    suspend fun routes(from: GeoPoint, to: GeoPoint, heading: Double?, avoidTolls: Boolean, avoidHighways: Boolean,
                       lang: RVLang): List<NavRoute> {
        val body = Valhalla.routeRequestBody(from, to, heading, lang.valhallaLanguage, 2, avoidTolls, avoidHighways)
        val text = post("route", body)
        val routes = try {
            Valhalla.parseRoutes(text, lang)
        } catch (e: ValhallaError) {
            throw RoutingException(serverError(e.code, e.message))
        }
        return routes.filter { it.polyline.size >= 2 }.ifEmpty { throw RoutingException(L("valhallaErr.noRoute")) }
    }

    suspend fun traceAttributes(polyline: List<GeoPoint>, edgeWalk: Boolean): List<RouteEdgeAttributes> {
        if (polyline.size < 2) throw RoutingException(L("valhallaErr.noRoute"))
        val text = post("trace_attributes", Valhalla.traceAttributesBody(polyline, edgeWalk))
        val edges = try {
            Valhalla.parseTraceAttributes(text, polyline)
        } catch (e: ValhallaError) {
            throw RoutingException(serverError(e.code, e.message))
        }
        return edges.ifEmpty { throw RoutingException(L("valhallaErr.noRoute")) }
    }

    private suspend fun post(path: String, body: String): String {
        val url = url(endpoint, path) ?: throw RoutingException(
            if (endpoint.isEmpty()) L("valhallaErr.noEndpoint") else L("valhallaErr.badEndpoint", endpoint))
        val response = spacer.run {
            try {
                Http.post(url, body.toByteArray(Charsets.UTF_8), "application/json", TIMEOUT_MS)
            } catch (e: Http.NetworkException) {
                throw RoutingException(when (e.kind) {
                    Http.NetworkException.Kind.OFFLINE, Http.NetworkException.Kind.HOST_NOT_FOUND -> L("valhallaErr.offline")
                    Http.NetworkException.Kind.TIMEOUT -> L("valhallaErr.timeout")
                    else -> L("valhallaErr.network", e.message ?: "")
                })
            }
        }
        if (response.status == 429) throw RoutingException(L("valhallaErr.rateLimited"))
        if (response.status in 400..599) {
            // Valhalla returns its JSON error body with 4xx; turn it into a readable message.
            val parsed = try { Valhalla.parseRoutes(response.text); null } catch (e: ValhallaError) { e } catch (_: Exception) { null }
            if (parsed != null && !parsed.isGenericParseFailure) throw RoutingException(serverError(parsed.code, parsed.message))
            throw RoutingException(L("valhallaErr.http", response.status))
        }
        return response.text
    }

    private fun serverError(code: Int?, message: String): String = when (code) {
        170 -> L("valhallaErr.170")
        171 -> L("valhallaErr.171")
        154 -> L("valhallaErr.154")
        442 -> L("valhallaErr.noRoute")
        443, 444 -> L("valhallaErr.443")
        else -> {
            val text = message.trim().ifEmpty { L("common.unknownError") }
            if (code != null) L("valhallaErr.withCode", code, text) else L("valhallaErr.other", text)
        }
    }
}

/** OSRM `/route` with alternatives (port of iOS `OSRMClient`). */
class OsrmClient(endpoint: String = OSRM.defaultEndpoint) {
    @Volatile var endpoint: String = endpoint
    private val spacer = RequestSpacer()

    suspend fun routes(from: GeoPoint, to: GeoPoint, lang: RVLang): List<NavRoute> {
        val url = OSRM.routeURL(endpoint, from, to, true) ?: throw RoutingException(L("navErr.osrm"))
        val response = spacer.run {
            try {
                Http.get(url, timeoutMs = 25_000)
            } catch (e: Http.NetworkException) {
                throw RoutingException("OSRM: " + Http.describe(e))
            }
        }
        if (response.status == 429) throw RoutingException("OSRM: HTTP 429")
        return try {
            OSRM.parseRoutes(response.text, lang).ifEmpty { throw OSRMError("NoRoute", "no routes") }
        } catch (e: OSRMError) {
            // The core describes OSRM codes in Russian only; show the raw code/message for other languages.
            throw RoutingException(if (lang == RVLang.RU) e.russianDescription
            else "OSRM ${e.code ?: ""}: ${e.message}".trim())
        } catch (e: Exception) {
            if (response.status != 200) throw RoutingException("OSRM: HTTP ${response.status}")
            throw RoutingException(L("navErr.osrm"))
        }
    }
}
