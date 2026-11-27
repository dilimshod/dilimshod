package uz.roadvis.app.learning

import android.text.format.DateFormat
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CloudUpload
import androidx.compose.material.icons.filled.DeleteForever
import androidx.compose.material.icons.filled.SystemUpdate
import androidx.compose.material3.AlertDialog
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
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import uz.roadvis.app.app.AppSettings
import uz.roadvis.app.app.AppState
import uz.roadvis.app.l10n.L
import uz.roadvis.app.settings.ButtonRow
import uz.roadvis.app.settings.ChoiceRows
import uz.roadvis.app.settings.FormSection
import uz.roadvis.app.settings.RowDivider
import uz.roadvis.app.settings.TextRow
import uz.roadvis.app.settings.ToggleRow
import uz.roadvis.app.settings.UrlFieldRow
import uz.roadvis.app.settings.ValueRow
import uz.roadvis.app.settings.validatedUrl
import uz.roadvis.app.ui.RV
import uz.roadvis.core.LearningStorePolicy
import java.util.Date
import java.util.Locale

/**
 * Settings → "Improve recognition" (continuous learning, `RoadVis/docs/TRAINING_API.md`): the same rows and buttons
 * as the iOS section — master toggle (off by default), server, device token, Wi-Fi only, location, storage limit,
 * model downloads, status, actions and the privacy note.
 */
@Composable
fun LearningSettingsSection(app: AppState) {
    val s = app.settings
    val context = app.context
    val scope = rememberCoroutineScope()
    var confirmDelete by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        withContext(Dispatchers.IO) {
            LearningStatus.refresh(context)
            ModelStore.refresh(context)
        }
    }
    val on = s.learningEnabled

    FormSection(header = L("learning.title"), footer = L("learning.privacy")) {
        ToggleRow(L("learning.enabled"), on, { s.learningEnabled = it })
        RowDivider()
        UrlFieldRow(L("learning.server"), s.learningServerUrl, AppSettings.DEFAULT_LEARNING_SERVER, { s.learningServerUrl = it },
            error = if (validatedUrl(s.learningServerUrl) == null) L("navset.badURL") else null)
        TokenFieldRow(s.learningToken) { s.learningToken = it }
        RowDivider()
        ToggleRow(L("learning.wifiOnly"), s.learningWifiOnly, { s.learningWifiOnly = it }, enabled = on)
        ToggleRow(L("learning.sendLocation"), s.learningSendLocation, { s.learningSendLocation = it }, enabled = on)
        ToggleRow(L("learning.downloadModels"), s.learningDownloadModels, { s.learningDownloadModels = it }, enabled = on)
        RowDivider()
        TextRow(L("learning.storageLimit"), secondary = true)
        ChoiceRows(
            LearningStorePolicy.STORAGE_LIMIT_CHOICES_MB.map { it.toString() to "$it MB" },
            LearningStorePolicy.normalizedLimitMb(s.learningStorageLimitMb).toString(),
            { v ->
                val mb = v.toInt()
                s.learningStorageLimitMb = mb
                scope.launch(Dispatchers.IO) {
                    LearningStore(context).applyRetention(mb)
                    LearningStatus.refresh(context)
                }
            },
            enabled = on,
        )
        RowDivider()
        // Status
        ValueRow(L("learning.status.collected"),
            "${LearningStatus.pendingCount} · ${megabytes(LearningStatus.pendingBytes)}")
        ValueRow(L("learning.status.uploaded"), LearningStatus.uploadedTotal.toString())
        ValueRow(L("learning.status.deleted"), "${LearningStatus.deletedByQuality} / ${LearningStatus.deletedByLimit}")
        ValueRow(L("learning.status.lastUpload"), dateTime(LearningStatus.lastUploadMillis))
        LearningStatus.lastError?.let { TextRow(it, color = RV.caution) }
        val model = ModelStore.shownInfo
        ValueRow(L("learning.status.model"), if (model == null) L("learning.model.bundled") else model.version)
        if (model != null) {
            val details = listOfNotNull(model.createdAt?.take(10), model.map50?.let { "mAP50 ${"%.2f".format(Locale.US, it)}" })
            if (details.isNotEmpty()) TextRow(details.joinToString(" · "), secondary = true)
        }
        RowDivider()
        // Actions
        ButtonRow(L("learning.uploadNow"), Icons.Filled.CloudUpload, enabled = on) {
            LearningStatus.actionMessage = null
            LearningFeature.uploadNow(context, s)
        }
        ButtonRow(L("learning.checkModel"), Icons.Filled.SystemUpdate) {
            LearningStatus.actionMessage = null
            LearningFeature.checkModelNow(context, s)
        }
        ButtonRow(L("learning.deleteAll"), Icons.Filled.DeleteForever, destructive = true) { confirmDelete = true }
        LearningStatus.actionMessage?.takeIf { it.isNotEmpty() }?.let { TextRow(it, secondary = true) }
    }

    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            text = { Text(L("learning.deleteAll.confirm")) },
            confirmButton = {
                TextButton(onClick = {
                    confirmDelete = false
                    scope.launch(Dispatchers.IO) {
                        LearningStore(context).deleteAll()
                        LearningStatus.refresh(context)
                    }
                }) { Text(L("common.delete"), color = RV.danger) }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text(L("common.cancel")) } },
        )
    }
}

/** Device token as a password field (the value is never shown in clear text). */
@Composable
private fun TokenFieldRow(value: String, onChange: (String) -> Unit) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
        Text(L("learning.token"), color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
        OutlinedTextField(
            value = value,
            onValueChange = { onChange(it.trim()) },
            singleLine = true,
            visualTransformation = PasswordVisualTransformation(),
            textStyle = androidx.compose.ui.text.TextStyle(fontFamily = FontFamily.Monospace, fontSize = 13.sp, color = Color.White),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false),
            modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
        )
    }
}

private fun megabytes(bytes: Long): String = "%.1f MB".format(Locale.US, bytes / (1024.0 * 1024.0))

private fun dateTime(millis: Long): String =
    if (millis <= 0) "—" else DateFormat.format("yyyy-MM-dd HH:mm", Date(millis)).toString()
