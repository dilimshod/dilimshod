package uz.roadvis.app.cabinet

import android.content.Intent
import android.net.Uri
import android.text.format.DateFormat
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.DeleteForever
import androidx.compose.material.icons.filled.OpenInBrowser
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import uz.roadvis.app.app.AppState
import uz.roadvis.app.camera.CameraOwnership
import uz.roadvis.app.l10n.L
import uz.roadvis.app.settings.ButtonRow
import uz.roadvis.app.settings.FormSection
import uz.roadvis.app.settings.RowDivider
import uz.roadvis.app.settings.SecondaryText
import uz.roadvis.app.settings.TextRow
import uz.roadvis.app.settings.ToggleRow
import uz.roadvis.app.settings.ValueRow
import uz.roadvis.app.settings.validatedUrl
import uz.roadvis.app.ui.RV
import uz.roadvis.core.CabinetApi
import uz.roadvis.core.QRLoginPayload
import java.util.Date

/**
 * Settings → «Кабинет водителя» (`RoadVis/docs/CABINET_API.md`): enable switch (off by default, enabling registers
 * the phone), driver name (synced to the server), status, the QR website login, «Открыть кабинет», Wi-Fi-only uploads,
 * «Удалить мои данные на сервере» and the privacy note. The server is the learning server URL.
 */
@Composable
fun CabinetSettingsSection(app: AppState) {
    val s = app.settings
    val context = app.context
    val scope = rememberCoroutineScope()
    val on = s.cabinetEnabled
    var confirmDelete by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }

    // QR login flow: scanner → confirmation → approval → result.
    var showScanner by remember { mutableStateOf(false) }
    var pendingLogin by remember { mutableStateOf<QRLoginPayload?>(null) }
    var approving by remember { mutableStateOf(false) }
    var loginResult by remember { mutableStateOf<Pair<Boolean, String>?>(null) }

    LaunchedEffect(on) {
        CabinetStatus.refresh(context)
        if (on) CabinetService.refreshNow(context, s)
    }

    fun openScanner() {
        // Set before the dialog is composed: the camera screen releases the back camera first.
        CameraOwnership.scannerOpen = true
        showScanner = true
    }

    FormSection(header = L("cabinet.title"), footer = L("cabinet.privacy")) {
        ToggleRow(L("cabinet.enabled"), on, { enabled ->
            message = null
            s.cabinetEnabled = enabled
        }, subtitle = L("cabinet.enabled.hint"))
        if (on && s.deviceToken.isEmpty()) {
            TextRow(if (CabinetStatus.lastError == null) L("cabinet.registering") else L("cabinet.notRegistered"), secondary = true)
        }
        RowDivider()
        DriverNameField(s.cabinetDriverName) { name -> scope.launch { CabinetService.rename(context, s, name) } }
        RowDivider()

        // The prominent QR login button.
        Button(
            onClick = { message = null; openScanner() },
            enabled = on,
            colors = ButtonDefaults.buttonColors(containerColor = RV.accent),
            modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp).padding(horizontal = 16.dp, vertical = 6.dp),
        ) {
            Icon(Icons.Filled.QrCodeScanner, null, modifier = Modifier.size(22.dp))
            Spacer(Modifier.size(10.dp))
            Text(L("cabinet.qr.button"), fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
        }
        ButtonRow(L("cabinet.openWebsite"), Icons.Filled.OpenInBrowser) {
            val base = validatedUrl(s.learningServerUrl) ?: return@ButtonRow
            try {
                context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(CabinetApi.websiteUrl(base))).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            } catch (_: Exception) {}
        }
        RowDivider()

        // Status
        ValueRow(L("cabinet.status.points"), if (on) CabinetStatus.points.toString() else "—")
        ValueRow(L("cabinet.status.level"), if (on) CabinetStatus.level.toString() else "—")
        ValueRow(L("cabinet.status.trips"), if (on) CabinetStatus.tripCount.toString() else "—")
        ValueRow(L("cabinet.status.pending"), CabinetStatus.pendingCount.toString())
        ValueRow(L("cabinet.status.lastSync"), dateTime(CabinetStatus.lastSyncMillis))
        CabinetStatus.lastError?.let { TextRow(it, color = RV.caution) }
        ButtonRow(L("cabinet.refresh"), Icons.Filled.Sync, enabled = on) {
            message = null
            scope.launch { CabinetService.refreshNow(context, s) }
        }
        RowDivider()
        ToggleRow(L("cabinet.wifiOnly"), s.cabinetWifiOnly, { s.cabinetWifiOnly = it }, enabled = on)
        ValueRow(L("cabinet.server"), serverLabel(s.learningServerUrl))
        TextRow(L("cabinet.server.hint"), secondary = true)
        RowDivider()
        ButtonRow(L("cabinet.delete"), Icons.Filled.DeleteForever, destructive = true,
            enabled = !CabinetStatus.busy && (on || s.cabinetToken.isNotEmpty())) { confirmDelete = true }
        if (CabinetStatus.busy) {
            Column(Modifier.padding(horizontal = 16.dp, vertical = 6.dp)) { CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.dp) }
        }
        message?.let { TextRow(it, secondary = true) }
    }

    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text(L("cabinet.delete")) },
            text = { Text(L("cabinet.delete.confirm")) },
            confirmButton = {
                TextButton(onClick = {
                    confirmDelete = false
                    CabinetStatus.busy = true
                    scope.launch {
                        val error = CabinetService.deleteMyData(context, s)
                        CabinetStatus.busy = false
                        message = error ?: L("cabinet.delete.done")
                    }
                }) { Text(L("common.delete"), color = RV.danger) }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text(L("common.cancel")) } },
        )
    }

    if (showScanner) {
        QrScannerScreen(
            onResult = { text ->
                showScanner = false
                when (val r = QRLoginPayload.check(text, s.learningServerUrl)) {
                    is QRLoginPayload.Result.Valid -> pendingLogin = r.payload
                    is QRLoginPayload.Result.Invalid -> loginResult = false to when (r.failure) {
                        QRLoginPayload.Failure.FOREIGN_SITE -> L("cabinet.qr.error.foreign", hostOf(text))
                        QRLoginPayload.Failure.NOT_A_LINK, QRLoginPayload.Failure.INVALID_PARAMETERS -> L("cabinet.qr.error.invalid")
                    }
                }
            },
            onCancel = { showScanner = false },
        )
    }

    pendingLogin?.let { payload ->
        val name = s.cabinetDriverName.ifBlank { CabinetService.defaultDriverName() }
        AlertDialog(
            onDismissRequest = { if (!approving) pendingLogin = null },
            title = { Text(L("cabinet.qr.confirm.title", name)) },
            text = {
                Column {
                    Text(L("cabinet.qr.confirm.site", payload.host))
                    if (approving) {
                        Spacer(Modifier.size(12.dp))
                        CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.dp)
                        Text(L("cabinet.qr.approving"), color = SecondaryText, fontSize = 13.sp)
                    }
                }
            },
            confirmButton = {
                TextButton(enabled = !approving, onClick = {
                    approving = true
                    scope.launch {
                        val result = CabinetService.approveLogin(context, s, payload)
                        approving = false
                        pendingLogin = null
                        loginResult = when (result) {
                            CabinetService.ApproveResult.Approved -> true to L("cabinet.qr.success")
                            is CabinetService.ApproveResult.Failed -> false to result.message
                        }
                    }
                }) { Text(L("cabinet.qr.confirm.login"), fontWeight = FontWeight.SemiBold) }
            },
            dismissButton = {
                TextButton(enabled = !approving, onClick = { pendingLogin = null }) { Text(L("common.cancel")) }
            },
        )
    }

    loginResult?.let { (ok, text) ->
        AlertDialog(
            onDismissRequest = { loginResult = null },
            text = { Text(text) },
            title = { Text(if (ok) L("cabinet.qr.success.title") else L("cabinet.qr.error.title")) },
            confirmButton = { TextButton(onClick = { loginResult = null }) { Text(L("common.ok")) } },
            dismissButton = if (ok || !on) null else {
                { TextButton(onClick = { loginResult = null; openScanner() }) { Text(L("cabinet.qr.scanAgain")) } }
            },
        )
    }
}

/** Driver name, saved (and sent to the server) 1.5 s after the last keystroke or on «Done». */
@Composable
private fun DriverNameField(stored: String, onSave: (String) -> Unit) {
    var text by remember(stored) { mutableStateOf(stored) }
    LaunchedEffect(text) {
        if (text.isBlank() || text.trim() == stored) return@LaunchedEffect
        delay(1500)
        onSave(text)
    }
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
        Text(L("cabinet.driverName"), color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
        OutlinedTextField(
            value = text,
            onValueChange = { text = it.take(MAX_NAME_LENGTH) },
            placeholder = { Text(CabinetService.defaultDriverName()) },
            singleLine = true,
            textStyle = androidx.compose.ui.text.TextStyle(fontSize = 15.sp, color = Color.White),
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = { if (text.isNotBlank() && text.trim() != stored) onSave(text) }),
            modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
        )
        Text(L("cabinet.driverName.hint"), color = SecondaryText, fontSize = 12.sp, modifier = Modifier.padding(top = 4.dp))
    }
}

private const val MAX_NAME_LENGTH = 60

private fun serverLabel(url: String): String =
    validatedUrl(url)?.removePrefix("https://")?.removePrefix("http://")?.trimEnd('/') ?: L("navset.badURL")

private fun hostOf(text: String): String = try {
    java.net.URI(text.trim()).host ?: text.take(60)
} catch (_: Exception) {
    text.take(60)
}

private fun dateTime(millis: Long): String =
    if (millis <= 0) "—" else DateFormat.format("yyyy-MM-dd HH:mm", Date(millis)).toString()
