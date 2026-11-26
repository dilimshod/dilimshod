package uz.roadvis.core

import kotlin.math.abs

/** Loads files from `src/test/resources/fixtures` (copied from the Swift test fixtures). */
object RoadFixture {
    fun data(name: String, ext: String = "json"): ByteArray {
        val stream = RoadFixture::class.java.getResourceAsStream("/fixtures/$name.$ext")
            ?: throw AssertionError("missing fixture $name.$ext")
        return stream.use { it.readBytes() }
    }

    fun text(name: String, ext: String = "json"): String = String(data(name, ext), Charsets.UTF_8)
}

/** Local metric frame used by `overpass_roads_tashkent.json` (origin: Amir Temur square). */
object TashkentFrame {
    val origin = GeoPoint(41.3111, 69.2797)

    /** `x` metres east, `y` metres north of the origin (north/south first, then east/west — like the fixture generator). */
    fun xy(x: Double, y: Double): GeoPoint {
        val p = Geo.destination(origin, if (y >= 0) 0.0 else 180.0, abs(y))
        return Geo.destination(p, if (x >= 0) 90.0 else 270.0, abs(x))
    }
}
