package uz.roadvis.core

import java.util.Locale

/** Hand-off of the destination to other navigation apps. */
object ExternalNavigation {
    /**
     * Waze universal link `https://waze.com/ul?ll=<lat>,<lon>&navigate=yes`: opens the Waze app when installed
     * (it builds its own route to the point), otherwise the Waze website. null for an invalid point.
     */
    fun wazeURL(destination: GeoPoint): String? {
        if (!destination.isValid) return null
        return "https://waze.com/ul?ll=" + coordinateText(destination.latitude) + "," +
            coordinateText(destination.longitude) + "&navigate=yes"
    }

    /** Locale-independent decimal degrees with 6 fractional digits ("41.311081"). */
    internal fun coordinateText(degrees: Double): String = String.format(Locale.US, "%.6f", degrees)
}
