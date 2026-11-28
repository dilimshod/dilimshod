package uz.roadvis.app.app

import androidx.compose.runtime.Composable
import uz.roadvis.app.about.AboutHubScreen
import uz.roadvis.app.about.AppDescriptionScreen
import uz.roadvis.app.about.DataSourcesScreen
import uz.roadvis.app.about.DevelopersScreen
import uz.roadvis.app.about.OfferScreen
import uz.roadvis.app.settings.FullScreenSheet
import uz.roadvis.app.settings.SettingsScreen
import uz.roadvis.app.settings.SheetNav
import uz.roadvis.app.settings.SheetRoute
import uz.roadvis.app.settings.rememberSheetNav
import uz.roadvis.app.trips.TripHistoryScreen
import uz.roadvis.app.trips.TripReportScreen

/**
 * Settings / trip history / trip report / about sheets, shown as full-screen dialogs over both screens. Each sheet
 * has its own back stack (iOS NavigationStack); the trip report (after a recording stops) is the topmost one.
 */
@Composable
fun FeatureSheets(app: AppState) {
    if (app.showSettings) {
        val close = { app.showSettings = false }
        FullScreenSheet(close) { SheetHost(app, rememberSheetNav(SheetRoute.Settings, close)) }
    }
    if (app.showTripHistory) {
        val close = { app.showTripHistory = false }
        FullScreenSheet(close) { SheetHost(app, rememberSheetNav(SheetRoute.History, close)) }
    }
    if (app.showAbout) {
        val close = { app.showAbout = false }
        FullScreenSheet(close) { SheetHost(app, rememberSheetNav(SheetRoute.AboutHub, close)) }
    }
    val tripId = app.presentedTripId
    if (tripId != null) {
        val close = { app.presentedTripId = null }
        FullScreenSheet(close) { SheetHost(app, rememberSheetNav(SheetRoute.Report(tripId), close)) }
    }
}

@Composable
private fun SheetHost(app: AppState, nav: SheetNav) {
    when (val route = nav.top) {
        SheetRoute.Settings -> SettingsScreen(app, nav)
        SheetRoute.History -> TripHistoryScreen(app, nav)
        is SheetRoute.Report -> TripReportScreen(app, route.tripId, nav, leadingDone = nav.stack.size == 1)
        SheetRoute.AboutHub -> AboutHubScreen(nav)
        SheetRoute.AboutDescription -> AppDescriptionScreen(nav)
        SheetRoute.Offer -> OfferScreen(nav)
        SheetRoute.Developers -> DevelopersScreen(nav)
        SheetRoute.DataSources -> DataSourcesScreen(nav)
    }
}
