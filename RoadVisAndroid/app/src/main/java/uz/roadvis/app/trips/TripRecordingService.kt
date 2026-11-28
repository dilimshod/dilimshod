package uz.roadvis.app.trips

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import uz.roadvis.app.l10n.L
import uz.roadvis.app.settings.TL

/**
 * Keeps the process (and its GPS updates) alive while a trip is recorded with the app in the background. Android
 * requires a foreground service with a visible notification for background location; it uses a silent
 * minimum-importance channel (no status-bar icon, no sound) and there are no recording controls on screen.
 */
class TripRecordingService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION else 0
            ServiceCompat.startForeground(this, NOTIFICATION_ID, notification(this), type)
        } catch (_: Exception) {
            // No location permission / not allowed from the background: recording continues while the app is open.
            stopSelf()
        }
        return START_NOT_STICKY
    }

    companion object {
        private const val CHANNEL_ID = "rv.tripRecording"
        private const val NOTIFICATION_ID = 4107

        fun start(context: Context) {
            // A location-type foreground service needs a granted location permission (SecurityException in
            // startForeground on Android 14+); the stopSelf() fallback before startForeground would then crash the
            // app with "did not then call Service.startForeground()". Without permission there is nothing to keep alive.
            val fine = ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION)
            val coarse = ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION)
            if (fine != PackageManager.PERMISSION_GRANTED && coarse != PackageManager.PERMISSION_GRANTED) return
            try {
                ContextCompat.startForegroundService(context, Intent(context, TripRecordingService::class.java))
            } catch (_: Exception) {
                // ForegroundServiceStartNotAllowedException etc. — recording still works in the foreground.
            }
        }

        fun stop(context: Context) {
            try {
                context.stopService(Intent(context, TripRecordingService::class.java))
            } catch (_: Exception) {
            }
        }

        private fun notification(context: Context): android.app.Notification {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val nm = context.getSystemService(NotificationManager::class.java)
                val channel = NotificationChannel(CHANNEL_ID, TL("android.tripNotif.channel"), NotificationManager.IMPORTANCE_MIN)
                channel.setShowBadge(false)
                channel.setSound(null, null)
                channel.enableVibration(false)
                nm?.createNotificationChannel(channel)
            }
            val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            val pending = launch?.let {
                PendingIntent.getActivity(context, 0, it, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            }
            return NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_menu_mylocation)
                .setContentTitle(L("trip.recording"))
                .setContentText(TL("android.tripNotif.text"))
                .setPriority(NotificationCompat.PRIORITY_MIN)
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
                .setOngoing(true)
                .setSilent(true)
                .setShowWhen(false)
                .setContentIntent(pending)
                .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_DEFERRED)
                .build()
        }
    }
}
