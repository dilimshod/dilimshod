package uz.roadvis.app.cabinet

import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONArray
import uz.roadvis.app.RoadVisApp
import uz.roadvis.app.app.AppSettings
import uz.roadvis.app.app.AppState
import uz.roadvis.app.l10n.L
import uz.roadvis.app.l10n.LocalizationManager
import uz.roadvis.app.learning.LearningUploader
import uz.roadvis.app.roaddata.Http
import uz.roadvis.app.settings.validatedUrl
import uz.roadvis.app.trips.TripStore
import uz.roadvis.core.CabinetApi
import uz.roadvis.core.CabinetTripPayload
import uz.roadvis.core.QRLoginPayload
import uz.roadvis.core.Trip
import java.util.concurrent.TimeUnit

/** Called once from [AppState.start]: settings observer, retry of pending uploads on app start. */
fun installCabinet(app: AppState) {
    CabinetService.install(app)
}

/**
 * Status of the driver cabinet shown in Settings, persisted in the app's SharedPreferences (`rv.cabinet.*`): the
 * pending trip-upload queue (trip ids), last sync, and the profile numbers from `GET /api/v1/me`.
 * Compose state is updated on the main thread; the queue is guarded by one lock (worker, recorder and UI threads).
 */
object CabinetStatus {
    private const val K_PENDING = "rv.cabinet.pending"
    private const val K_LAST_SYNC = "rv.cabinet.lastSyncMillis"
    private const val K_POINTS = "rv.cabinet.points"
    private const val K_LEVEL = "rv.cabinet.level"
    private const val K_TRIP_COUNT = "rv.cabinet.tripCount"
    private const val K_LAST_ERROR = "rv.cabinet.lastError"

    private val main = Handler(Looper.getMainLooper())
    private val lock = Any()

    var pendingCount by mutableIntStateOf(0); private set
    var lastSyncMillis by mutableLongStateOf(0L); private set
    var points by mutableIntStateOf(0); private set
    var level by mutableIntStateOf(1); private set
    /** Trips the server holds for this driver (`tripCount` of `/me`). */
    var tripCount by mutableIntStateOf(0); private set
    var lastError by mutableStateOf<String?>(null); private set
    /** True while a registration / rename / delete started from Settings runs. */
    var busy by mutableStateOf(false)

    private fun prefs(context: Context): SharedPreferences =
        context.applicationContext.getSharedPreferences("roadvis", Context.MODE_PRIVATE)

    fun pendingIds(context: Context): List<String> = synchronized(lock) {
        val raw = prefs(context).getString(K_PENDING, null) ?: return emptyList()
        try {
            val arr = JSONArray(raw)
            (0 until arr.length()).map { arr.getString(it) }
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun writePending(context: Context, ids: List<String>) {
        val arr = JSONArray()
        ids.forEach { arr.put(it) }
        prefs(context).edit().putString(K_PENDING, arr.toString()).commit()
    }

    /** Adds a trip id (once); the queue keeps at most [MAX_PENDING] ids (the oldest are dropped). */
    fun addPending(context: Context, id: String) {
        synchronized(lock) {
            val ids = pendingIds(context).toMutableList()
            if (id !in ids) ids.add(id)
            while (ids.size > MAX_PENDING) ids.removeAt(0)
            writePending(context, ids)
        }
        refresh(context)
    }

    fun removePending(context: Context, id: String) {
        synchronized(lock) { writePending(context, pendingIds(context).filter { it != id }) }
        refresh(context)
    }

    fun recordSync(context: Context, nowMillis: Long = System.currentTimeMillis()) {
        prefs(context).edit().putLong(K_LAST_SYNC, nowMillis).remove(K_LAST_ERROR).apply()
        refresh(context)
    }

    fun recordProfile(context: Context, profile: CabinetApi.Profile) {
        prefs(context).edit().putInt(K_POINTS, profile.points).putInt(K_LEVEL, profile.level)
            .putInt(K_TRIP_COUNT, profile.tripCount).apply()
        refresh(context)
    }

    fun recordError(context: Context, message: String?) {
        prefs(context).edit().apply { if (message == null) remove(K_LAST_ERROR) else putString(K_LAST_ERROR, message) }.apply()
        refresh(context)
    }

    /** Forgets the queue and the profile numbers (data deleted on the server, or the token is no longer valid). */
    fun clear(context: Context) {
        synchronized(lock) {
            prefs(context).edit().remove(K_PENDING).remove(K_LAST_SYNC).remove(K_POINTS).remove(K_LEVEL)
                .remove(K_TRIP_COUNT).remove(K_LAST_ERROR).commit()
        }
        refresh(context)
    }

    fun refresh(context: Context) {
        val p = prefs(context)
        val pending = pendingIds(context).size
        val sync = p.getLong(K_LAST_SYNC, 0L)
        val pts = p.getInt(K_POINTS, 0)
        val lvl = p.getInt(K_LEVEL, 1)
        val trips = p.getInt(K_TRIP_COUNT, 0)
        val error = p.getString(K_LAST_ERROR, null)
        main.post {
            pendingCount = pending
            lastSyncMillis = sync
            points = pts
            level = lvl
            tripCount = trips
            lastError = error
        }
    }

    /** Upper bound of the pending list (200 trips/day is the server limit; a phone never needs more). */
    const val MAX_PENDING = 200
}

/** WorkManager entry point of the cabinet sync (pending trips, driver-name rename, profile refresh). */
class CabinetSyncWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val settings = CabinetService.settings(applicationContext) ?: return Result.retry()
        return when (CabinetService.sync(applicationContext, settings)) {
            CabinetService.SyncOutcome.DONE -> Result.success()
            CabinetService.SyncOutcome.RETRY -> Result.retry()
        }
    }
}

/**
 * Driver cabinet client (`RoadVis/docs/CABINET_API.md` §1, §2, §4): registration of the phone as a driver profile,
 * `GET / PATCH / DELETE /api/v1/me`, the automatic upload of finished trips (pending queue + WorkManager with a network
 * constraint and exponential back-off) and the QR login approval. Uses the learning server URL
 * ([AppSettings.learningServerUrl]) and the one device token ([AppSettings.deviceToken]).
 */
object CabinetService {
    const val WORK_SYNC = "rv.cabinet.sync"

    /** First retry after 1 min, doubling (WorkManager caps the back-off at 5 h). */
    private const val BACKOFF_SECONDS = 60L

    private val registerMutex = Mutex()
    private var installed = false

    fun install(app: AppState) {
        if (installed) return
        installed = true
        val s = app.settings
        val context = app.context
        CabinetStatus.refresh(context)
        MainScope().launch {
            var first = true
            snapshotFlow { s.cabinetEnabled to s.cabinetWifiOnly }.collect { (enabled, _) ->
                if (enabled) {
                    // App start: keep a sync that is waiting for its back-off; a settings change replaces it.
                    scheduleSync(context, s, if (first) ExistingWorkPolicy.KEEP else ExistingWorkPolicy.REPLACE)
                } else {
                    try { WorkManager.getInstance(context).cancelUniqueWork(WORK_SYNC) } catch (_: Exception) {}
                }
                first = false
            }
        }
    }

    /** The app's settings (null if the application object is not set up yet). */
    fun settings(context: Context): AppSettings? = (context.applicationContext as? RoadVisApp)?.stateOrNull?.settings

    // Trips

    /**
     * Hook of the trip recorder: a finished and saved trip is queued and uploaded right away (when the cabinet is on
     * and the trip is long enough, contract §2).
     */
    fun onTripSaved(context: Context, trip: Trip) {
        val s = settings(context) ?: return
        if (!s.cabinetEnabled) return
        if (!CabinetTripPayload.shouldUpload(trip)) return
        CabinetStatus.addPending(context, trip.id.toString())
        // A few seconds: the trip store writes the final file (with the A / B names) on its own thread.
        scheduleSync(context, s, ExistingWorkPolicy.REPLACE, initialDelaySeconds = 5)
    }

    fun scheduleSync(context: Context, s: AppSettings, policy: ExistingWorkPolicy, initialDelaySeconds: Long = 0) {
        val wm = try { WorkManager.getInstance(context) } catch (_: Exception) { return }
        val request = OneTimeWorkRequestBuilder<CabinetSyncWorker>()
            .setInitialDelay(initialDelaySeconds, TimeUnit.SECONDS)
            .setConstraints(Constraints.Builder()
                .setRequiredNetworkType(if (s.cabinetWifiOnly) NetworkType.UNMETERED else NetworkType.CONNECTED).build())
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, BACKOFF_SECONDS, TimeUnit.SECONDS)
            .build()
        wm.enqueueUniqueWork(WORK_SYNC, policy, request)
    }

    enum class SyncOutcome { DONE, RETRY }

    /**
     * One sync run: registration if needed, pending rename, every pending trip (oldest first), then `GET /me`.
     * RETRY when something should be tried again later (network, 429, 5xx).
     */
    suspend fun sync(context: Context, s: AppSettings): SyncOutcome = withContext(Dispatchers.IO) {
        if (!s.cabinetEnabled) return@withContext SyncOutcome.DONE
        val base = validatedUrl(s.learningServerUrl) ?: run {
            CabinetStatus.recordError(context, L("navset.badURL"))
            return@withContext SyncOutcome.DONE
        }
        val token = when (val r = ensureRegistered(context, s)) {
            is Registration.Ok -> r.token
            is Registration.Failed -> return@withContext if (r.retry) SyncOutcome.RETRY else SyncOutcome.DONE
        }
        var retry = false
        if (s.cabinetDriverNameDirty && s.cabinetDriverName.isNotBlank()) {
            when (pushName(context, s, base, token, s.cabinetDriverName.trim())) {
                CallResult.OK -> {}
                CallResult.UNAUTHORIZED -> return@withContext SyncOutcome.DONE
                CallResult.FAILED -> retry = true
            }
        }
        val appVersion = appVersion(context)
        val headers = headers(context, token)
        var uploaded = 0
        for (id in CabinetStatus.pendingIds(context)) {
            if (!s.cabinetEnabled) break
            val trip = TripStore.readTrip(context, id)
            val payload = trip?.let { CabinetTripPayload.build(it, appVersion) }
            if (payload == null) {
                // Deleted on the phone, unreadable, or too short: nothing to upload.
                CabinetStatus.removePending(context, id)
                continue
            }
            val status = try {
                Http.send("POST", CabinetApi.url(base, CabinetApi.TRIPS_PATH), payload.toString().toByteArray(Charsets.UTF_8),
                    "application/json", timeoutMs = 60_000, headers = headers).status
            } catch (e: Exception) {
                CabinetStatus.recordError(context, Http.describe(e))
                retry = true
                break
            }
            when (CabinetApi.tripUploadOutcome(status)) {
                CabinetApi.TripUploadOutcome.UPLOADED -> {
                    CabinetStatus.removePending(context, id)
                    uploaded += 1
                }
                CabinetApi.TripUploadOutcome.REJECTED -> {
                    CabinetStatus.removePending(context, id)
                    CabinetStatus.recordError(context, L("cabinet.error.tripRejected", status))
                }
                CabinetApi.TripUploadOutcome.UNAUTHORIZED -> {
                    handleUnauthorized(context, s)
                    return@withContext SyncOutcome.DONE
                }
                CabinetApi.TripUploadOutcome.RETRY_LATER -> {
                    CabinetStatus.recordError(context, L("cabinet.error.http", status))
                    retry = true
                    break
                }
            }
        }
        if (uploaded > 0 && !retry) CabinetStatus.recordSync(context)
        if (refreshProfile(context, s) == CallResult.FAILED && CabinetStatus.pendingIds(context).isNotEmpty()) retry = true
        if (retry) SyncOutcome.RETRY else SyncOutcome.DONE
    }

    // Registration and profile

    sealed class Registration {
        data class Ok(val token: String) : Registration()
        /** [retry]: a transient failure (network, 429, 5xx); otherwise the user has to act (bad URL, rejected). */
        data class Failed(val message: String, val retry: Boolean) : Registration()
    }

    /**
     * The device token, registering the phone first (`POST /api/v1/devices/register`) when the cabinet is on and the
     * app has no token yet. The driver name defaults to the device model; language = app language.
     */
    suspend fun ensureRegistered(context: Context, s: AppSettings): Registration = withContext(Dispatchers.IO) {
        registerMutex.withLock {
            val existing = s.deviceToken
            if (existing.isNotEmpty()) return@withLock Registration.Ok(existing)
            if (!s.cabinetEnabled) return@withLock Registration.Failed(L("cabinet.error.disabled"), retry = false)
            val base = validatedUrl(s.learningServerUrl)
                ?: return@withLock Registration.Failed(L("navset.badURL"), retry = false).also { CabinetStatus.recordError(context, it.message) }
            val name = s.cabinetDriverName.trim().ifEmpty { defaultDriverName() }
            val body = CabinetApi.registerBody(CabinetApi.PLATFORM_ANDROID, appVersion(context), deviceName(), name,
                LocalizationManager.language.raw)
            val response = try {
                Http.send("POST", CabinetApi.url(base, CabinetApi.REGISTER_PATH), body.toString().toByteArray(Charsets.UTF_8),
                    "application/json", headers = mapOf("User-Agent" to LearningUploader.userAgent(context)))
            } catch (e: Exception) {
                val message = Http.describe(e)
                CabinetStatus.recordError(context, message)
                return@withLock Registration.Failed(message, retry = true)
            }
            val registration = if (response.status in 200..299) CabinetApi.parseRegistration(response.text) else null
            if (registration == null) {
                val message = L("cabinet.error.register", response.status)
                CabinetStatus.recordError(context, message)
                return@withLock Registration.Failed(message, retry = response.status == 429 || response.status >= 500)
            }
            withContext(Dispatchers.Main) {
                s.cabinetToken = registration.deviceToken
                s.cabinetDriverId = registration.driverId
                s.cabinetDriverName = registration.driverName?.takeIf { it.isNotBlank() } ?: name
                s.cabinetDriverNameDirty = false
            }
            CabinetStatus.recordError(context, null)
            Registration.Ok(registration.deviceToken)
        }
    }

    enum class CallResult { OK, UNAUTHORIZED, FAILED }

    /** `GET /api/v1/me`: points, level, trip count (and the server's driver name unless a rename is pending). */
    suspend fun refreshProfile(context: Context, s: AppSettings): CallResult = withContext(Dispatchers.IO) {
        val base = validatedUrl(s.learningServerUrl) ?: return@withContext CallResult.FAILED
        val token = s.deviceToken.ifEmpty { return@withContext CallResult.FAILED }
        val response = try {
            Http.get(CabinetApi.url(base, CabinetApi.ME_PATH), headers = headers(context, token))
        } catch (e: Exception) {
            CabinetStatus.recordError(context, Http.describe(e))
            return@withContext CallResult.FAILED
        }
        when {
            response.status == 401 -> {
                handleUnauthorized(context, s)
                CallResult.UNAUTHORIZED
            }
            response.status in 200..299 -> {
                val profile = CabinetApi.parseProfile(response.text) ?: return@withContext CallResult.FAILED
                applyProfile(context, s, profile)
                CabinetStatus.recordSync(context)
                CallResult.OK
            }
            else -> {
                CabinetStatus.recordError(context, L("cabinet.error.http", response.status))
                CallResult.FAILED
            }
        }
    }

    /** Settings «Обновить»: registration if needed, then the profile and a sync of anything pending. */
    suspend fun refreshNow(context: Context, s: AppSettings) {
        if (!s.cabinetEnabled) return
        val r = ensureRegistered(context, s)
        if (r is Registration.Ok) {
            refreshProfile(context, s)
            if (CabinetStatus.pendingIds(context).isNotEmpty() || s.cabinetDriverNameDirty) {
                scheduleSync(context, s, ExistingWorkPolicy.REPLACE)
            }
        }
    }

    /**
     * Renames the driver: stored locally at once, `PATCH /api/v1/me` now; when that fails the sync work retries it.
     */
    suspend fun rename(context: Context, s: AppSettings, name: String) {
        val trimmed = name.trim()
        if (trimmed.isEmpty()) return
        withContext(Dispatchers.Main) {
            s.cabinetDriverName = trimmed
            s.cabinetDriverNameDirty = true
        }
        if (!s.cabinetEnabled) return
        val base = validatedUrl(s.learningServerUrl) ?: return
        val token = s.deviceToken
        if (token.isEmpty()) {
            // Not registered yet: the name goes with the registration.
            scheduleSync(context, s, ExistingWorkPolicy.REPLACE)
            return
        }
        if (pushName(context, s, base, token, trimmed) == CallResult.FAILED) scheduleSync(context, s, ExistingWorkPolicy.REPLACE)
    }

    private suspend fun pushName(context: Context, s: AppSettings, base: String, token: String, name: String): CallResult {
        val response = try {
            Http.send("PATCH", CabinetApi.url(base, CabinetApi.ME_PATH), CabinetApi.renameBody(name).toString().toByteArray(Charsets.UTF_8),
                "application/json", headers = headers(context, token))
        } catch (e: Exception) {
            CabinetStatus.recordError(context, Http.describe(e))
            return CallResult.FAILED
        }
        return when {
            response.status == 401 -> {
                handleUnauthorized(context, s)
                CallResult.UNAUTHORIZED
            }
            response.status in 200..299 -> {
                CabinetApi.parseProfile(response.text)?.let { CabinetStatus.recordProfile(context, it) }
                withContext(Dispatchers.Main) {
                    // Only clear the flag when the name was not changed again meanwhile.
                    if (s.cabinetDriverName.trim() == name) s.cabinetDriverNameDirty = false
                }
                CabinetStatus.recordError(context, null)
                CallResult.OK
            }
            else -> {
                CabinetStatus.recordError(context, L("cabinet.error.http", response.status))
                CallResult.FAILED
            }
        }
    }

    private suspend fun applyProfile(context: Context, s: AppSettings, profile: CabinetApi.Profile) {
        CabinetStatus.recordProfile(context, profile)
        withContext(Dispatchers.Main) {
            if (profile.driverId.isNotEmpty()) s.cabinetDriverId = profile.driverId
            val serverName = profile.driverName?.trim().orEmpty()
            if (!s.cabinetDriverNameDirty && serverName.isNotEmpty()) s.cabinetDriverName = serverName
        }
    }

    /** Result of «Удалить мои данные на сервере»: null on success, else the error to show. */
    suspend fun deleteMyData(context: Context, s: AppSettings): String? = withContext(Dispatchers.IO) {
        val token = s.deviceToken
        if (token.isNotEmpty()) {
            val base = validatedUrl(s.learningServerUrl) ?: return@withContext L("navset.badURL")
            val response = try {
                Http.send("DELETE", CabinetApi.url(base, CabinetApi.ME_PATH), headers = headers(context, token))
            } catch (e: Exception) {
                return@withContext Http.describe(e)
            }
            // 401 / 404: the profile and token are already gone on the server.
            if (response.status !in 200..299 && response.status != 401 && response.status != 404) {
                return@withContext L("cabinet.error.http", response.status)
            }
        }
        try { WorkManager.getInstance(context).cancelUniqueWork(WORK_SYNC) } catch (_: Exception) {}
        withContext(Dispatchers.Main) {
            s.cabinetEnabled = false
            s.cabinetToken = ""
            s.cabinetDriverId = ""
            s.cabinetDriverNameDirty = false
            // The server deleted the token that was used, also a manually entered training token.
            if (s.learningToken.isNotBlank()) s.learningToken = ""
        }
        CabinetStatus.clear(context)
        null
    }

    /**
     * 401 from a cabinet endpoint. A registered token that the server no longer knows (data deleted on the website)
     * is forgotten and the cabinet switched off, so the phone does not silently create a new profile; a manually
     * entered training token is left for the user to fix.
     */
    private suspend fun handleUnauthorized(context: Context, s: AppSettings) {
        if (s.learningToken.isNotBlank()) {
            CabinetStatus.recordError(context, L("cabinet.error.tokenRejected"))
            return
        }
        withContext(Dispatchers.Main) {
            s.cabinetEnabled = false
            s.cabinetToken = ""
            s.cabinetDriverId = ""
        }
        CabinetStatus.clear(context)
        CabinetStatus.recordError(context, L("cabinet.error.unauthorized"))
    }

    // QR login

    sealed class ApproveResult {
        data object Approved : ApproveResult()
        data class Failed(val message: String) : ApproveResult()
    }

    /** `POST /api/v1/auth/qr/approve` with the device token (contract §4). */
    suspend fun approveLogin(context: Context, s: AppSettings, payload: QRLoginPayload): ApproveResult = withContext(Dispatchers.IO) {
        val base = validatedUrl(s.learningServerUrl) ?: return@withContext ApproveResult.Failed(L("navset.badURL"))
        val token = when (val r = ensureRegistered(context, s)) {
            is Registration.Ok -> r.token
            is Registration.Failed -> return@withContext ApproveResult.Failed(r.message)
        }
        val body = CabinetApi.approveBody(payload.challengeId, payload.nonce).toString().toByteArray(Charsets.UTF_8)
        val status = try {
            Http.send("POST", CabinetApi.url(base, CabinetApi.QR_APPROVE_PATH), body, "application/json",
                headers = headers(context, token)).status
        } catch (e: Exception) {
            return@withContext ApproveResult.Failed(L("cabinet.qr.error.network", Http.describe(e)))
        }
        when (CabinetApi.approveOutcome(status)) {
            CabinetApi.ApproveOutcome.APPROVED -> ApproveResult.Approved
            CabinetApi.ApproveOutcome.EXPIRED -> ApproveResult.Failed(L("cabinet.qr.error.expired"))
            CabinetApi.ApproveOutcome.ALREADY_USED -> ApproveResult.Failed(L("cabinet.qr.error.used"))
            CabinetApi.ApproveOutcome.UNAUTHORIZED -> {
                handleUnauthorized(context, s)
                ApproveResult.Failed(L("cabinet.error.unauthorized"))
            }
            CabinetApi.ApproveOutcome.FAILED -> ApproveResult.Failed(L("cabinet.error.http", status))
        }
    }

    // Helpers

    private fun headers(context: Context, token: String): Map<String, String> =
        mapOf("Authorization" to "Bearer $token", "User-Agent" to LearningUploader.userAgent(context))

    fun appVersion(context: Context): String = try {
        context.packageManager.getPackageInfo(context.packageName, 0).versionName ?: "1.0"
    } catch (_: Exception) {
        "1.0"
    }

    /** Default driver name: the device model ("Pixel 8"). */
    fun defaultDriverName(): String = Build.MODEL?.trim()?.takeIf { it.isNotEmpty() } ?: "Android"

    /** "Google Pixel 8" (manufacturer + model, without repeating the manufacturer). */
    fun deviceName(): String {
        val model = Build.MODEL?.trim().orEmpty()
        val maker = Build.MANUFACTURER?.trim().orEmpty().replaceFirstChar { it.uppercase() }
        return when {
            model.isEmpty() -> maker.ifEmpty { "Android" }
            maker.isEmpty() || model.startsWith(maker, ignoreCase = true) -> model
            else -> "$maker $model"
        }
    }
}
