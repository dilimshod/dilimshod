package uz.roadvis.app.settings

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import uz.roadvis.app.l10n.L
import uz.roadvis.app.ui.RV
import kotlin.math.abs
import kotlin.math.roundToInt

/** Screens shown inside the feature sheets (each sheet keeps its own back stack, like an iOS NavigationStack). */
sealed interface SheetRoute {
    data object Settings : SheetRoute
    data object History : SheetRoute
    data class Report(val tripId: String) : SheetRoute
    data object AboutHub : SheetRoute
    data object AboutDescription : SheetRoute
    data object Offer : SheetRoute
    data object Developers : SheetRoute
    data object DataSources : SheetRoute
}

/** Back stack of one sheet. */
class SheetNav(root: SheetRoute, val close: () -> Unit) {
    val stack = mutableStateListOf(root)
    val top: SheetRoute get() = stack.last()
    val canPop: Boolean get() = stack.size > 1
    fun push(route: SheetRoute) { stack += route }
    fun pop() { if (canPop) stack.removeAt(stack.lastIndex) else close() }
}

@Composable
fun rememberSheetNav(root: SheetRoute, close: () -> Unit): SheetNav = remember(root) { SheetNav(root, close) }

val SheetBackground = Color(0xFF0B0D10)
val GroupBackground = Color(0xFF1A1D22)
val SecondaryText = Color(0xFF9A9AA0)

/** Full-screen dialog over the whole app (camera and navigator). */
@Composable
fun FullScreenSheet(onDismiss: () -> Unit, content: @Composable () -> Unit) {
    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false),
    ) {
        Box(Modifier.fillMaxSize().background(SheetBackground)) { content() }
    }
}

/**
 * Title bar + content of a sheet screen: back arrow when the stack can pop, else «Done» (iOS confirmation action).
 * [leadingDone] puts «Done» on the left (iOS trip report sheet).
 */
@Composable
fun SheetScaffold(
    title: String,
    nav: SheetNav,
    leadingDone: Boolean = false,
    actions: @Composable RowScope.() -> Unit = {},
    content: @Composable ColumnScope.() -> Unit,
) {
    BackHandler { nav.pop() }
    Column(Modifier.fillMaxSize().safeDrawingPadding()) {
        Row(Modifier.fillMaxWidth().heightIn(min = 52.dp).padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.width(96.dp), contentAlignment = Alignment.CenterStart) {
                when {
                    nav.canPop -> IconButton(onClick = { nav.pop() }) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, TL("android.common.back"), tint = RV.accent)
                    }
                    leadingDone -> TextButton(onClick = nav.close) { Text(L("common.done"), fontWeight = FontWeight.SemiBold, color = RV.accent) }
                }
            }
            Text(title, Modifier.weight(1f), fontWeight = FontWeight.SemiBold, fontSize = 17.sp, maxLines = 1,
                overflow = TextOverflow.Ellipsis, textAlign = androidx.compose.ui.text.style.TextAlign.Center, color = Color.White)
            Row(Modifier.width(96.dp), horizontalArrangement = Arrangement.End, verticalAlignment = Alignment.CenterVertically) {
                actions()
                if (!nav.canPop && !leadingDone) {
                    TextButton(onClick = nav.close) { Text(L("common.done"), fontWeight = FontWeight.SemiBold, color = RV.accent) }
                }
            }
        }
        Column(Modifier.fillMaxSize(), content = content)
    }
}

// Form building blocks (iOS Form / Section look).

@Composable
fun FormSection(header: String? = null, footer: String? = null, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
        if (header != null) {
            Text(header.uppercase(), fontSize = 12.sp, color = SecondaryText, modifier = Modifier.padding(start = 12.dp, bottom = 6.dp))
        }
        Column(Modifier.fillMaxWidth().background(GroupBackground, RoundedCornerShape(RV.Radius.control)).padding(vertical = 4.dp)) {
            content()
        }
        if (footer != null) {
            Text(footer, fontSize = 12.sp, color = SecondaryText, modifier = Modifier.padding(start = 12.dp, end = 12.dp, top = 6.dp))
        }
    }
}

@Composable
fun RowDivider() = HorizontalDivider(Modifier.padding(start = 16.dp), color = Color.White.copy(alpha = 0.08f))

@Composable
private fun RowLabel(title: String, subtitle: String?, icon: ImageVector?, modifier: Modifier, subtitleColor: Color = SecondaryText) {
    Row(modifier, verticalAlignment = Alignment.CenterVertically) {
        if (icon != null) {
            Icon(icon, null, tint = RV.accent, modifier = Modifier.size(22.dp))
            Spacer(Modifier.width(12.dp))
        }
        Column {
            Text(title, color = Color.White, fontSize = 16.sp)
            if (subtitle != null) Text(subtitle, color = subtitleColor, fontSize = 12.sp)
        }
    }
}

@Composable
fun ToggleRow(
    title: String,
    checked: Boolean,
    onChange: (Boolean) -> Unit,
    subtitle: String? = null,
    icon: ImageVector? = null,
    enabled: Boolean = true,
) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 48.dp).alpha(if (enabled) 1f else 0.45f)
            .clickable(enabled = enabled) { onChange(!checked) }.padding(horizontal = 16.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RowLabel(title, subtitle, icon, Modifier.weight(1f))
        Spacer(Modifier.width(8.dp))
        Switch(checked = checked, onCheckedChange = onChange, enabled = enabled,
            colors = SwitchDefaults.colors(checkedTrackColor = RV.safe.copy(alpha = 0.85f)))
    }
}

/** iOS Stepper: title, value text, − / + buttons. */
@Composable
fun StepperRow(
    title: String,
    value: Double,
    range: ClosedFloatingPointRange<Double>,
    step: Double,
    valueText: String,
    onChange: (Double) -> Unit,
    enabled: Boolean = true,
) {
    fun snap(v: Double) = ((v / step).roundToInt() * step).coerceIn(range.start, range.endInclusive)
    Row(
        Modifier.fillMaxWidth().heightIn(min = 48.dp).alpha(if (enabled) 1f else 0.45f).padding(start = 16.dp, end = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, color = Color.White, fontSize = 16.sp, modifier = Modifier.weight(1f))
        Text(valueText, color = SecondaryText, fontSize = 15.sp, fontFamily = FontFamily.Monospace)
        Spacer(Modifier.width(6.dp))
        IconButton(onClick = { onChange(snap(value - step)) }, enabled = enabled && value - step >= range.start - 1e-9) {
            Icon(Icons.Filled.Remove, "−", tint = RV.accent)
        }
        IconButton(onClick = { onChange(snap(value + step)) }, enabled = enabled && value + step <= range.endInclusive + 1e-9) {
            Icon(Icons.Filled.Add, "+", tint = RV.accent)
        }
    }
}

@Composable
fun SliderRow(
    title: String,
    valueText: String,
    value: Double,
    range: ClosedFloatingPointRange<Double>,
    step: Double,
    onChange: (Double) -> Unit,
    enabled: Boolean = true,
) {
    val steps = ((range.endInclusive - range.start) / step).roundToInt() - 1
    Column(Modifier.fillMaxWidth().alpha(if (enabled) 1f else 0.45f).padding(horizontal = 16.dp, vertical = 6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(title, color = Color.White, fontSize = 16.sp, modifier = Modifier.weight(1f))
            Text(valueText, color = SecondaryText, fontSize = 15.sp, fontFamily = FontFamily.Monospace)
        }
        Slider(
            value = value.toFloat(),
            onValueChange = { v ->
                val snapped = (range.start + ((v - range.start) / step).roundToInt() * step).coerceIn(range.start, range.endInclusive)
                if (abs(snapped - value) > 1e-9) onChange(snapped)
            },
            valueRange = range.start.toFloat()..range.endInclusive.toFloat(),
            steps = steps.coerceAtLeast(0),
            enabled = enabled,
        )
    }
}

/** Inline single-choice list (iOS `.pickerStyle(.inline)`): one row per option with a check mark. */
@Composable
fun ChoiceRows(options: List<Pair<String, String>>, selected: String, onSelect: (String) -> Unit, enabled: Boolean = true) {
    options.forEachIndexed { i, (value, label) ->
        if (i > 0) RowDivider()
        Row(
            Modifier.fillMaxWidth().heightIn(min = 46.dp).alpha(if (enabled) 1f else 0.45f)
                .clickable(enabled = enabled) { onSelect(value) }.padding(horizontal = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(label, color = Color.White, fontSize = 16.sp, modifier = Modifier.weight(1f))
            if (value == selected) Icon(Icons.Filled.Check, null, tint = RV.accent)
        }
    }
}

@Composable
fun NavRow(title: String, icon: ImageVector? = null, trailing: String? = null, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable(onClick = onClick).padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RowLabel(title, null, icon, Modifier.weight(1f))
        if (trailing != null) Text(trailing, color = SecondaryText, fontSize = 15.sp)
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = SecondaryText)
    }
}

@Composable
fun ValueRow(title: String, value: String, icon: ImageVector? = null, valueColor: Color = SecondaryText) {
    Row(Modifier.fillMaxWidth().heightIn(min = 46.dp).padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
        RowLabel(title, null, icon, Modifier.weight(1f))
        Text(value, color = valueColor, fontSize = 15.sp)
    }
}

@Composable
fun ButtonRow(title: String, icon: ImageVector? = null, destructive: Boolean = false, enabled: Boolean = true, onClick: () -> Unit) {
    val color = if (destructive) RV.danger else RV.accent
    Row(
        Modifier.fillMaxWidth().heightIn(min = 46.dp).alpha(if (enabled) 1f else 0.45f)
            .clickable(enabled = enabled, onClick = onClick).padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) {
            Icon(icon, null, tint = color, modifier = Modifier.size(22.dp))
            Spacer(Modifier.width(12.dp))
        }
        Text(title, color = color, fontSize = 16.sp)
    }
}

@Composable
fun TextRow(text: String, secondary: Boolean = false, color: Color? = null, bold: Boolean = false) {
    Text(
        text,
        color = color ?: if (secondary) SecondaryText else Color.White,
        fontSize = if (secondary) 13.sp else 15.sp,
        fontWeight = if (bold) FontWeight.SemiBold else FontWeight.Normal,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
    )
}

@Composable
fun UrlFieldRow(label: String, value: String, placeholder: String, onChange: (String) -> Unit, error: String? = null) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
        Text(label, color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
        OutlinedTextField(
            value = value,
            onValueChange = onChange,
            placeholder = { Text(placeholder, fontFamily = FontFamily.Monospace, fontSize = 13.sp) },
            singleLine = true,
            textStyle = androidx.compose.ui.text.TextStyle(fontFamily = FontFamily.Monospace, fontSize = 13.sp, color = Color.White),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false),
            modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
        )
        if (error != null) Text(error, color = RV.caution, fontSize = 12.sp, modifier = Modifier.padding(top = 4.dp))
    }
}
