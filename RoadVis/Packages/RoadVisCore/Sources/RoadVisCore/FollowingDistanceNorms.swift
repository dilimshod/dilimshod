import Foundation

/// Reference texts about following distance shown in the app ("Требования к дистанции").
/// Each item says whether it is a legal norm or a recommendation and where it comes from (verified November 2026).
public enum FollowingDistanceNorms {
    public enum Status: String, Sendable {
        case norm = "Норма"
        case recommendation = "Рекомендация"
        case appSetting = "Настройка приложения"
    }

    public struct Item: Identifiable, Hashable, Sendable {
        public let id: String
        public let title: String
        public let text: String
        public let status: Status
        public let source: String
        public let url: String?
    }

    public static let rulesDocument =
        "Правила дорожного движения Республики Узбекистан, утв. постановлением Кабинета Министров №172 от 12.04.2022 " +
        "(действуют с 01.05.2022; редакция от 30.10.2026). Официальный текст — на узбекском языке; русский текст на lex.uz — неофициальный перевод."

    public static let items: [Item] = [
        Item(id: "uz-73", title: "Дистанция в движении (ПДД РУз, п.73)",
             text: "Водитель должен соблюдать такую дистанцию до движущегося впереди транспортного средства, которая гарантировала бы избежание столкновения в случае его экстренной остановки, а также безопасный боковой интервал. Числового значения пункт не содержит.",
             status: .norm, source: "ПДД РУз, п.73", url: "https://lex.uz/ru/docs/5953887"),
        Item(id: "uz-74", title: "Тихоходные и длинные ТС вне населённых пунктов (п.74)",
             text: "На двухполосных дорогах вне населённых пунктов водители ТС, скорость которых не должна превышать 50 км/ч, и ТС длиной более 7 м должны держать дистанцию, позволяющую обгоняющим перестроиться. Чисел нет.",
             status: .norm, source: "ПДД РУз, п.74", url: "https://lex.uz/ru/docs/5953887"),
        Item(id: "uz-144", title: "Буксировка (п.144)",
             text: "На гибкой сцепке расстояние между ТС — 4–6 м, на жёсткой — не более 4 м.",
             status: .norm, source: "ПДД РУз, п.144", url: "https://lex.uz/ru/docs/5953887"),
        Item(id: "uz-3.16", title: "Знак 3.16 «Ограничение минимальной дистанции»",
             text: "Запрещается движение с дистанцией меньше указанной на знаке.",
             status: .norm, source: "ПДД РУз, приложение (знаки)", url: "https://lex.uz/ru/docs/5953887"),
        Item(id: "rec-2s", title: "Правило двух секунд",
             text: "В движении держите интервал не менее 2 секунд до впереди идущего ТС; на мокрой дороге — минимум вдвое больше (4 с); на обледенелой — до 10 раз больше.",
             status: .recommendation, source: "UK Highway Code, правило 126",
             url: "https://www.gov.uk/guidance/the-highway-code/general-rules-techniques-and-advice-for-all-drivers-and-riders-103-to-158"),
        Item(id: "app-snow", title: "Снег",
             text: "На заснеженной дороге приложение использует интервал 3× от сухого (6 с при 2 с).",
             status: .appSetting, source: "Выбор приложения (числовой нормы нет)", url: nil),
        Item(id: "rec-stopped", title: "Дистанция при остановке (пробка, светофор)",
             text: "В ПДД РУз числовой нормы нет. Совет «шины и асфальт»: остановитесь так, чтобы видеть, где задние шины впереди стоящего автомобиля касаются дороги — тогда хватит места для объезда. Приложение по умолчанию предупреждает, если оценка дистанции меньше 2 м. В тоннеле — не менее 5 м (UK Highway Code, правило 126).",
             status: .recommendation, source: "IAM RoadSmart (совет); UK Highway Code 126; порог 2 м — настройка приложения", url: nil),
        Item(id: "phys-stop", title: "Остановочный путь",
             text: "S = v·t + v²/(2·μ·g): время реакции t = 1 с (настраивается), коэффициент сцепления μ: сухо 0,7, мокро 0,35, снег 0,2, лёд 0,1. Это инженерная оценка, а не измерение.",
             status: .recommendation, source: "UK Highway Code (таблица остановочного пути), AASHTO, PIARC",
             url: "https://assets.publishing.service.gov.uk/media/65f97642aa9b760011fbda4e/the-highway-code-stopping-distances.pdf"),
    ]

    /// One-line explanation shown under the distance HUD.
    public static let disclaimer =
        "Расстояние оценивается по одной камере (≈, погрешность может быть большой). ПДД РУз (п.73) требуют безопасную дистанцию без числового значения; показанные числа — рекомендации."
}
