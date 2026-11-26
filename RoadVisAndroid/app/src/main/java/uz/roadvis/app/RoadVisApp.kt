package uz.roadvis.app

import android.app.Application
import uz.roadvis.app.app.AppState
import uz.roadvis.app.l10n.LocalizationManager

class RoadVisApp : Application() {
    lateinit var state: AppState
        private set

    override fun onCreate() {
        super.onCreate()
        LocalizationManager.init(this)
        state = AppState(this)
    }
}
