package uz.roadvis.app.roaddata

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import uz.roadvis.app.l10n.L
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.ConnectException
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL
import java.net.UnknownHostException
import javax.net.ssl.SSLException
import kotlin.coroutines.coroutineContext

/** Plain HTTP over `HttpURLConnection` with the identifying User-Agent required by the OSM / FOSSGIS policies. */
object Http {
    /** Identifying client name (OSM tile, Nominatim, Overpass and FOSSGIS usage policies). */
    const val USER_AGENT = "RoadVis-Android/1.0 (+https://github.com/dilimshod)"

    class Response(val status: Int, val body: ByteArray, val headers: Map<String, List<String>>) {
        val text: String get() = String(body, Charsets.UTF_8)
        fun header(name: String): String? =
            headers.entries.firstOrNull { it.key?.equals(name, ignoreCase = true) == true }?.value?.firstOrNull()
    }

    /** Transport failure (no HTTP status), with a localized reason. */
    class NetworkException(val kind: Kind, message: String, cause: Throwable? = null) : IOException(message, cause) {
        enum class Kind { OFFLINE, TIMEOUT, HOST_NOT_FOUND, CANNOT_CONNECT, TLS, OTHER }
    }

    suspend fun get(url: String, timeoutMs: Int = 20_000, headers: Map<String, String> = emptyMap()): Response =
        request("GET", url, null, null, timeoutMs, headers)

    suspend fun post(url: String, body: ByteArray, contentType: String, timeoutMs: Int = 25_000,
                     headers: Map<String, String> = emptyMap()): Response =
        request("POST", url, body, contentType, timeoutMs, headers)

    private suspend fun request(method: String, url: String, body: ByteArray?, contentType: String?, timeoutMs: Int,
                                headers: Map<String, String>): Response = withContext(Dispatchers.IO) {
        val connection = try {
            URL(url).openConnection() as HttpURLConnection
        } catch (e: Exception) {
            throw NetworkException(NetworkException.Kind.OTHER, e.message ?: url, e)
        }
        try {
            connection.requestMethod = method
            connection.connectTimeout = timeoutMs.coerceAtMost(15_000)
            connection.readTimeout = timeoutMs
            connection.useCaches = false
            connection.instanceFollowRedirects = true
            connection.setRequestProperty("User-Agent", USER_AGENT)
            connection.setRequestProperty("Accept", "application/json")
            headers.forEach { (k, v) -> connection.setRequestProperty(k, v) }
            if (body != null) {
                connection.doOutput = true
                if (contentType != null) connection.setRequestProperty("Content-Type", contentType)
                connection.setFixedLengthStreamingMode(body.size)
                connection.outputStream.use { it.write(body) }
            }
            val status = connection.responseCode
            coroutineContext.ensureActive()
            val stream: InputStream? = if (status >= 400) connection.errorStream else connection.inputStream
            val data = stream?.use { readAll(it) } ?: ByteArray(0)
            Response(status, data, connection.headerFields.filterKeys { it != null })
        } catch (e: NetworkException) {
            throw e
        } catch (e: UnknownHostException) {
            throw NetworkException(NetworkException.Kind.HOST_NOT_FOUND, L("net.hostNotFound"), e)
        } catch (e: SocketTimeoutException) {
            throw NetworkException(NetworkException.Kind.TIMEOUT, L("net.timedOut"), e)
        } catch (e: ConnectException) {
            throw NetworkException(NetworkException.Kind.CANNOT_CONNECT, L("net.cannotConnect"), e)
        } catch (e: SSLException) {
            throw NetworkException(NetworkException.Kind.TLS, L("net.tls"), e)
        } catch (e: IOException) {
            throw NetworkException(NetworkException.Kind.OTHER, e.message ?: L("net.loadError"), e)
        } finally {
            connection.disconnect()
        }
    }

    private fun readAll(input: InputStream): ByteArray {
        val out = ByteArrayOutputStream()
        val buffer = ByteArray(16 * 1024)
        while (true) {
            val n = input.read(buffer)
            if (n < 0) break
            out.write(buffer, 0, n)
        }
        return out.toByteArray()
    }

    /** User-facing reason of any network error. */
    fun describe(error: Throwable): String = when (error) {
        is NetworkException -> when (error.kind) {
            NetworkException.Kind.OFFLINE -> L("net.noInternet")
            NetworkException.Kind.TIMEOUT -> L("net.timeout")
            else -> error.message ?: L("net.loadError")
        }
        else -> error.message ?: L("net.loadError")
    }
}

/** JSON files of the road data features in `filesDir/RoadVis/` (port of iOS `RoadDataPersistence`). */
object RoadDataPersistence {
    sealed class LoadResult {
        data object Missing : LoadResult()
        data class Loaded(val text: String) : LoadResult()
        data class Failed(val message: String) : LoadResult()
    }

    private fun dir(filesDir: java.io.File): java.io.File = java.io.File(filesDir, "RoadVis").also { it.mkdirs() }

    fun load(filesDir: java.io.File, name: String): LoadResult {
        val file = java.io.File(dir(filesDir), name)
        if (!file.exists()) return LoadResult.Missing
        return try {
            LoadResult.Loaded(file.readText())
        } catch (e: Exception) {
            LoadResult.Failed(L("persist.readFailed", name, e.message ?: ""))
        }
    }

    /** Moves an undecodable file aside so it is not overwritten silently. */
    fun quarantine(filesDir: java.io.File, name: String): String {
        val file = java.io.File(dir(filesDir), name)
        val backup = java.io.File(dir(filesDir), "$name.corrupt-${System.currentTimeMillis() / 1000}")
        file.renameTo(backup)
        return L("persist.corrupted", name, backup.name)
    }

    /** Atomic write (temp file + rename). */
    @Synchronized
    fun write(filesDir: java.io.File, name: String, text: String) {
        val target = java.io.File(dir(filesDir), name)
        val tmp = java.io.File(dir(filesDir), "$name.tmp")
        tmp.writeText(text)
        if (!tmp.renameTo(target)) {
            target.delete()
            if (!tmp.renameTo(target)) throw IOException("rename failed: $name")
        }
    }
}
