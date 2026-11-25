import SwiftUI

/// Settings sections of the navigator («Маршрутизация», «Пробки»). Its body consists of `Section`s only, so it is
/// meant to be placed inside the `Form` of `SettingsView`.
struct NavigationSettingsSection: View {
    @Environment(AppState.self) private var app
    @AppStorage(NavigatorSettingsKeys.osrmEndpoint) private var osrmEndpoint = OSRM.defaultEndpoint

    var body: some View {
        @Bindable var settings = app.settings

        Section {
            Picker("Построение маршрутов", selection: $settings.routingEngine) {
                ForEach(RoutingEngineOption.allCases) { engine in
                    Text(engine.displayName).tag(engine.rawValue)
                }
            }
            .pickerStyle(.inline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Сервер Valhalla")
                    .font(.subheadline.weight(.semibold))
                TextField(Valhalla.defaultEndpoint, text: $settings.valhallaEndpoint)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                if ValhallaClient.url(endpoint: settings.valhallaEndpoint, path: "route") == nil {
                    Label("Некорректный адрес: нужен http(s)-адрес сервера", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 4)

            if settings.valhallaEndpoint != Valhalla.defaultEndpoint {
                Button("Вернуть сервер Valhalla по умолчанию (FOSSGIS)") {
                    settings.valhallaEndpoint = Valhalla.defaultEndpoint
                }
                .frame(minHeight: 44)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Сервер OSRM")
                    .font(.subheadline.weight(.semibold))
                TextField(OSRM.defaultEndpoint, text: $osrmEndpoint)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                if OSRM.routeURL(endpoint: osrmEndpoint, from: GeoPoint(41.3, 69.2), to: GeoPoint(41.31, 69.21)) == nil {
                    Label("Некорректный адрес: нужен http(s)-адрес сервера OSRM (…/routed-car)",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 4)

            if osrmEndpoint != OSRM.defaultEndpoint {
                Button("Вернуть сервер OSRM по умолчанию (FOSSGIS)") {
                    osrmEndpoint = OSRM.defaultEndpoint
                }
                .frame(minHeight: 44)
            }

            Toggle("Ограничения скорости, полосы и светофоры по маршруту (Valhalla)",
                   isOn: $settings.routeAttributesEnabled)
                .frame(minHeight: 44)
        } header: {
            Text("Маршрутизация")
        } footer: {
            Text("«Авто» запрашивает одновременно Apple Maps (где Apple поддерживает маршруты — по данным Apple, "
                 + "в Узбекистане нет), Valhalla и OSRM, объединяет совпадающие маршруты (≥ 85 % общего пути), "
                 + "сравнивает варианты и выбирает самый быстрый; причина неудачи каждого источника показывается. "
                 + "Публичные серверы FOSSGIS (valhalla1.openstreetmap.de, routing.openstreetmap.de) бесплатны и "
                 + "предназначены для лёгкого некоммерческого использования: приложение отправляет каждому не больше "
                 + "одного запроса в секунду и указывает источник — © участники OpenStreetMap. Для частого "
                 + "использования укажите собственные серверы.")
        }

        Section {
            Toggle("Слой пробок Apple — где есть данные", isOn: $settings.showTrafficOnMap)
                .frame(minHeight: 44)

            VStack(alignment: .leading, spacing: 6) {
                Text("Свой источник тайлов пробок")
                    .font(.subheadline.weight(.semibold))
                TextField("https://…/{z}/{x}/{y}.png", text: $settings.trafficTileTemplate)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                if let problem = tileTemplateProblem(settings.trafficTileTemplate) {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 4)

            if !settings.trafficTileTemplate.isEmpty {
                Button("Отключить свой источник", role: .destructive) {
                    settings.trafficTileTemplate = ""
                }
                .frame(minHeight: 44)
            }
        } header: {
            Text("Пробки")
        } footer: {
            Text("Бесплатных данных о пробках в реальном времени для Узбекистана из открытых источников нет, а слой "
                 + "пробок Apple там пуст. Если у вас есть права или ключ доступа к сервису растровых тайлов пробок, "
                 + "укажите шаблон адреса с {z}, {x} и {y} — слой будет наложен на карту. Загруженность текущего "
                 + "участка в навигаторе оценивается по вашей собственной скорости (оценка, не данные о трафике).")
        }
    }

    /// Russian problem description for a non-empty, invalid tile template; nil when empty or valid.
    private func tileTemplateProblem(_ template: String) -> String? {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") {
            return "Незащищённые адреса http:// запрещены iOS (App Transport Security) — нужен https://"
        }
        if !lower.hasPrefix("https://") {
            return "Адрес должен начинаться с https://"
        }
        let missing = ["{z}", "{x}", "{y}"].filter { !trimmed.contains($0) }
        if !missing.isEmpty {
            return "В шаблоне не хватает: \(missing.joined(separator: ", "))"
        }
        return nil
    }
}
