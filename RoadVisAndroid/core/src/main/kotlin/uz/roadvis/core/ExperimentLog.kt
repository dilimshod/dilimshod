package uz.roadvis.core

import org.json.JSONObject
import java.io.File
import kotlin.math.max

// Dates are epoch milliseconds (`...Millis`) — see TripJson.kt.

/** One detection row of a research log. */
data class ExperimentRecord(
    val timestampMillis: Long,
    val frameIndex: Int,
    val trackID: Int? = null,
    val kind: VehicleKind,
    val label: String,
    /** Detector confidence (model score), not accuracy. */
    val confidence: Double,
    val box: BBox,
    val make: String? = null,
    val makeConfidence: Double? = null,
    val distanceMeters: Double? = null,
    val estimatedSpeedKmh: Double? = null,
    val lightColor: TrafficLightColor? = null,
    val latitude: Double? = null,
    val longitude: Double? = null,
    val ownSpeedKmh: Double? = null,
    /** The track was confirmed (≥ minHits detections) on this frame. */
    val isConfirmed: Boolean = true,
    /** Number of frames the track has been matched so far. */
    val trackHits: Int? = null,
    /** The object was the lead vehicle (closest in the own lane) on this frame. */
    val isLead: Boolean = false,
    /** Person role (colour heuristic ≈); null for other classes / undecided. */
    val personRole: PersonRole? = null,
) {
    fun toJson(): JSONObject {
        val o = JSONObject()
            .put("timestamp", timestampMillis)
            .put("frameIndex", frameIndex)
            .put("kind", kind.raw)
            .put("label", label)
            .put("confidence", confidence)
            .put("box", JSONObject().put("x", box.x).put("y", box.y).put("width", box.width).put("height", box.height))
            .put("isConfirmed", isConfirmed)
            .put("isLead", isLead)
        TripJson.putOpt(o, "trackID", trackID)
        TripJson.putOpt(o, "make", make)
        TripJson.putOpt(o, "makeConfidence", makeConfidence)
        TripJson.putOpt(o, "distanceMeters", distanceMeters)
        TripJson.putOpt(o, "estimatedSpeedKmh", estimatedSpeedKmh)
        TripJson.putOpt(o, "lightColor", lightColor?.raw)
        TripJson.putOpt(o, "personRole", personRole?.raw)
        TripJson.putOpt(o, "latitude", latitude)
        TripJson.putOpt(o, "longitude", longitude)
        TripJson.putOpt(o, "ownSpeedKmh", ownSpeedKmh)
        TripJson.putOpt(o, "trackHits", trackHits)
        return o
    }

    companion object {
        fun fromJson(o: JSONObject): ExperimentRecord {
            val b = o.getJSONObject("box")
            return ExperimentRecord(
                timestampMillis = o.getLong("timestamp"),
                frameIndex = o.getInt("frameIndex"),
                trackID = TripJson.optInt(o, "trackID"),
                kind = VehicleKind.fromRaw(o.getString("kind")) ?: VehicleKind.OTHER,
                label = o.getString("label"),
                confidence = o.getDouble("confidence"),
                box = BBox(b.getDouble("x"), b.getDouble("y"), b.getDouble("width"), b.getDouble("height")),
                make = TripJson.optString(o, "make"),
                makeConfidence = TripJson.optDouble(o, "makeConfidence"),
                distanceMeters = TripJson.optDouble(o, "distanceMeters"),
                estimatedSpeedKmh = TripJson.optDouble(o, "estimatedSpeedKmh"),
                lightColor = TripJson.optString(o, "lightColor")?.let { TrafficLightColor.fromRaw(it) },
                latitude = TripJson.optDouble(o, "latitude"),
                longitude = TripJson.optDouble(o, "longitude"),
                ownSpeedKmh = TripJson.optDouble(o, "ownSpeedKmh"),
                isConfirmed = o.optBoolean("isConfirmed", true),
                trackHits = TripJson.optInt(o, "trackHits"),
                isLead = o.optBoolean("isLead", false),
                personRole = TripJson.optString(o, "personRole")?.let { PersonRole.fromRaw(it) },
            )
        }
    }
}

/**
 * Research log of a recognition session. Two different quantities are exported and must not be confused:
 * per-frame detections (`detections.csv`) and unique tracked objects (`summary.csv`, counted once per confirmed track).
 */
class ExperimentLog(val modelName: String, val startedAtMillis: Long = System.currentTimeMillis()) {
    private val _records = mutableListOf<ExperimentRecord>()
    val records: List<ExperimentRecord> get() = _records
    var frameCount: Int = 0
        private set

    /** Hard cap to keep memory bounded on long sessions (≈ 200k rows). */
    var maxRecords: Int = 200_000
    var droppedRecords: Int = 0
        private set

    fun markFrame() {
        frameCount += 1
    }

    fun append(record: ExperimentRecord) {
        if (_records.size >= maxRecords) {
            droppedRecords += 1
            return
        }
        _records.add(record)
    }

    fun detectionsCSV(): String {
        val lines = ArrayList<String>(_records.size + 1)
        lines.add("timestamp,frame,track_id,class,label,confidence,x,y,width,height,make,make_confidence,distance_m_est,speed_kmh_est,light_color,person_role_est,lat,lon,own_speed_kmh,confirmed,track_hits,is_lead")
        for (r in _records) {
            val fields = listOf(
                TripJson.isoMillis(r.timestampMillis),
                r.frameIndex.toString(),
                r.trackID?.toString() ?: "",
                r.kind.raw,
                csvField(r.label),
                num(r.confidence),
                num(r.box.x, 4), num(r.box.y, 4), num(r.box.width, 4), num(r.box.height, 4),
                csvField(r.make),
                num(r.makeConfidence),
                num(r.distanceMeters, 1),
                num(r.estimatedSpeedKmh, 1),
                r.lightColor?.raw ?: "",
                r.personRole?.raw ?: "",
                num(r.latitude, 6), num(r.longitude, 6),
                num(r.ownSpeedKmh, 1),
                if (r.isConfirmed) "1" else "0",
                r.trackHits?.toString() ?: "",
                if (r.isLead) "1" else "0",
            )
            lines.add(fields.joinToString(","))
        }
        return lines.joinToString("\n") + "\n"
    }

    /** Per-class comparison of raw per-frame detections and unique tracked objects. */
    fun summaryCSV(uniqueCounts: Map<VehicleKind, Int>, endedAtMillis: Long): String {
        val frameDetections = HashMap<VehicleKind, Int>()
        val confirmedDetections = HashMap<VehicleKind, Int>()
        val confidenceSum = HashMap<VehicleKind, Double>()
        val trackIDs = HashMap<VehicleKind, MutableSet<Int>>()
        var leadRows = 0
        val leadDistances = mutableListOf<Double>()
        for (r in _records) {
            frameDetections[r.kind] = (frameDetections[r.kind] ?: 0) + 1
            if (r.isConfirmed) confirmedDetections[r.kind] = (confirmedDetections[r.kind] ?: 0) + 1
            confidenceSum[r.kind] = (confidenceSum[r.kind] ?: 0.0) + r.confidence
            r.trackID?.let { trackIDs.getOrPut(r.kind) { HashSet() }.add(it) }
            if (r.isLead) {
                leadRows += 1
                r.distanceMeters?.let { leadDistances.add(it) }
            }
        }
        val duration = max(0.0, (endedAtMillis - startedAtMillis) / 1000.0)
        val lines = mutableListOf(
            "# RoadVis experiment summary",
            "# model,${csvField(modelName)}",
            "# started,${TripJson.isoMillis(startedAtMillis)}",
            "# ended,${TripJson.isoMillis(endedAtMillis)}",
            "# duration_s,${num(duration, 1)}",
            "# processed_frames,$frameCount",
            "# dropped_rows,$droppedRecords",
            "# note,frame_detections = rows in detections.csv (one object on one frame); confirmed_detections = rows of confirmed tracks; track_ids = all track ids incl. short tentative ones; unique_tracked = objects counted once per confirmed track (the app's count); mean_confidence is model score, not accuracy",
            "# lead_vehicle_rows,$leadRows",
            "# lead_distance_median_m_est,${num(median(leadDistances), 1)}",
            "class,frame_detections,confirmed_detections,track_ids,unique_tracked,mean_confidence",
        )
        for (kind in VehicleKind.entries) {
            val det = frameDetections[kind] ?: 0
            val uniq = uniqueCounts[kind] ?: 0
            if (det <= 0 && uniq <= 0) continue
            val mean = if (det > 0) (confidenceSum[kind] ?: 0.0) / det else null
            lines.add("${kind.raw},$det,${confirmedDetections[kind] ?: 0},${trackIDs[kind]?.size ?: 0},$uniq,${num(mean)}")
        }
        val totalUnique = uniqueCounts.filterKeys { it.isVehicle }.values.sum()
        val vehicleRows = frameDetections.filterKeys { it.isVehicle }.values.sum()
        val vehicleConfirmed = confirmedDetections.filterKeys { it.isVehicle }.values.sum()
        val vehicleIDs = trackIDs.filterKeys { it.isVehicle }.values.sumOf { it.size }
        lines.add("vehicles_total,$vehicleRows,$vehicleConfirmed,$vehicleIDs,$totalUnique,")
        return lines.joinToString("\n") + "\n"
    }

    /** Writes `<prefix>_detections.csv` and `<prefix>_summary.csv` into [directory] and returns the files. */
    fun writeFiles(directory: File, uniqueCounts: Map<VehicleKind, Int>, endedAtMillis: Long): List<File> {
        directory.mkdirs()
        val stamp = TripJson.isoMillis(startedAtMillis).replace(":", "-").replace(".", "-")
        val prefix = "roadvis_$stamp"
        val det = File(directory, "${prefix}_detections.csv")
        val sum = File(directory, "${prefix}_summary.csv")
        det.writeText(detectionsCSV(), Charsets.UTF_8)
        sum.writeText(summaryCSV(uniqueCounts, endedAtMillis), Charsets.UTF_8)
        return listOf(det, sum)
    }

    companion object {
        internal fun num(v: Double?, digits: Int = 3): String = TripJson.number(v, digits)

        internal fun csvField(s: String?): String {
            if (s.isNullOrEmpty()) return ""
            return TripJson.escape(s)
        }

        internal fun median(values: List<Double>): Double? {
            if (values.isEmpty()) return null
            val v = values.sorted()
            return if (v.size % 2 == 1) v[v.size / 2] else (v[v.size / 2 - 1] + v[v.size / 2]) / 2
        }
    }
}
