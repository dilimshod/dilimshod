import Foundation

/// Text preparation for speaking Uzbek (Latin script) when iOS has no Uzbek voice.
///
/// iOS 17–26 ship no Uzbek `AVSpeechSynthesisVoice` (Uzbek is absent from Apple's VoiceOver / Spoken Content
/// language lists; only keyboards exist). `SpeechService` therefore speaks Uzbek with:
/// 1. any installed voice whose language starts with "uz" (e.g. a third-party Speech Synthesis Provider) — text as is;
/// 2. else a Turkish voice reading `forTurkishVoice(_:)` — Uzbek Latin respelled with Turkish letter values;
/// 3. else a Russian voice reading `forRussianVoice(_:)` — Uzbek Latin transliterated to Cyrillic.
/// Numbers are always spelled out in Uzbek words first, otherwise the Turkish / Russian voice would read them
/// in its own language. The result is an *approximate* pronunciation, never a native Uzbek voice.
/// Foundation only (unit-testable on Linux).
enum UzbekSpeechText {

    // MARK: Public API

    /// Uzbek Latin text → text a Turkish (tr-TR) voice pronounces close to Uzbek.
    /// o‘→o, g‘→g, sh→ş, ch→ç, j→c (dʒ), x→h, q→k, c→s, I→İ, tutuq belgisi (’) dropped; numbers in Uzbek words.
    static func forTurkishVoice(_ text: String) -> String {
        transliterate(prepare(text), rules: turkishRules, wordInitialE: nil)
    }

    /// Uzbek Latin text → Cyrillic that a Russian (ru-RU) voice pronounces close to Uzbek.
    static func forRussianVoice(_ text: String) -> String {
        transliterate(prepare(text), rules: cyrillicRules, wordInitialE: "э")
    }

    /// Spells numbers in Uzbek words, ordinals ("2-chorraha" → "ikkinchi chorraha") and expands units
    /// ("300 m" → "uch yuz metr", "60 km/soat" → "oltmish kilometr soatiga"). Output is still Uzbek Latin.
    static func prepare(_ text: String) -> String {
        var output = ""
        let tokens = tokenize(normalizeApostrophes(text))
        var index = 0
        var previousWasNumber = false
        while index < tokens.count {
            let token = tokens[index]
            switch token {
            case .number(let integer, let fraction):
                // Ordinal: "2-" followed by a letter.
                if index + 2 < tokens.count, case .other("-") = tokens[index + 1],
                   case .word = tokens[index + 2], fraction == nil, let value = Int(integer) {
                    output += ordinal(value) + " "
                    index += 2
                    previousWasNumber = false
                    continue
                }
                output += spellDecimal(integer: integer, fraction: fraction)
                previousWasNumber = true
            case .word(let word):
                if previousWasNumber, let unit = unitWord(word, next: index + 1 < tokens.count ? tokens[index + 1] : nil,
                                                          nextNext: index + 2 < tokens.count ? tokens[index + 2] : nil) {
                    output += unit.text
                    index += unit.consumed
                    previousWasNumber = false
                    continue
                }
                output += word
                previousWasNumber = false
            case .other(let string):
                output += string
                if !string.allSatisfy({ $0 == " " || $0 == "\u{00A0}" || $0 == "\u{202F}" }) {
                    previousWasNumber = false
                }
            }
            index += 1
        }
        return output
    }

    /// True when `text` contains Cyrillic letters (used to keep Russian text on a Russian voice).
    static func containsCyrillic(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
    }

    /// True when Cyrillic letters outnumber Latin letters (a Russian sentence, not a localized phrase that only
    /// contains a Cyrillic street name).
    static func isMostlyCyrillic(_ text: String) -> Bool {
        var cyrillic = 0, latin = 0
        for scalar in text.unicodeScalars {
            if (0x0400...0x04FF).contains(scalar.value) {
                cyrillic += 1
            } else if CharacterSet.letters.contains(scalar), scalar.isASCII {
                latin += 1
            }
        }
        return cyrillic > latin
    }

    /// Cyrillic words (e.g. OSM street names "улица Навои") → Latin letters, so an Uzbek-text or English voice
    /// can read a localized phrase that contains them. `english` uses English letter values (х → kh, ғ → gh).
    static func latinizingCyrillic(_ text: String, english: Bool = false) -> String {
        guard containsCyrillic(text) else { return text }
        var output = ""
        var previous: Character?
        for character in text {
            let lower = Character(character.lowercased())
            guard let mapped = cyrillicToLatin(lower, english: english, wordStart: !(previous?.isLetter ?? false)) else {
                output.append(character)
                previous = character
                continue
            }
            if character != lower, let first = mapped.first {
                output += first.uppercased() + mapped.dropFirst()
            } else {
                output += mapped
            }
            previous = character
        }
        return output
    }

    private static func cyrillicToLatin(_ c: Character, english: Bool, wordStart: Bool) -> String? {
        switch c {
        case "а": return "a"
        case "б": return "b"
        case "в": return "v"
        case "г": return "g"
        case "д": return "d"
        case "е": return wordStart ? "ye" : "e"
        case "ё": return "yo"
        case "ж": return english ? "zh" : "j"
        case "з": return "z"
        case "и": return "i"
        case "й": return "y"
        case "к": return "k"
        case "л": return "l"
        case "м": return "m"
        case "н": return "n"
        case "о": return "o"
        case "п": return "p"
        case "р": return "r"
        case "с": return "s"
        case "т": return "t"
        case "у": return "u"
        case "ф": return "f"
        case "х": return english ? "kh" : "x"
        case "ц": return "ts"
        case "ч": return "ch"
        case "ш": return "sh"
        case "щ": return "shch"
        case "ъ": return english ? "" : "’"
        case "ы": return "i"
        case "ь": return ""
        case "э": return "e"
        case "ю": return "yu"
        case "я": return "ya"
        case "ў": return english ? "o" : "o‘"
        case "қ": return "q"
        case "ғ": return english ? "gh" : "g‘"
        case "ҳ": return "h"
        default: return nil
        }
    }

    // MARK: Numbers

    private static let ones = ["nol", "bir", "ikki", "uch", "to'rt", "besh", "olti", "yetti", "sakkiz", "to'qqiz"]
    private static let tens = ["", "o'n", "yigirma", "o'ttiz", "qirq", "ellik", "oltmish", "yetmish", "sakson", "to'qson"]

    /// 0…999 999 999 in Uzbek words ("1250" → "ming ikki yuz ellik").
    static func spell(_ number: Int) -> String {
        if number < 0 { return "minus " + spell(-number) }
        if number == 0 { return ones[0] }
        var parts: [String] = []
        let millions = number / 1_000_000
        let thousands = (number / 1000) % 1000
        let rest = number % 1000
        if millions > 0 { parts.append(spellBelowThousand(millions) + " million") }
        if thousands == 1 {
            parts.append("ming")
        } else if thousands > 1 {
            parts.append(spellBelowThousand(thousands) + " ming")
        }
        if rest > 0 { parts.append(spellBelowThousand(rest)) }
        return parts.joined(separator: " ")
    }

    private static func spellBelowThousand(_ number: Int) -> String {
        var parts: [String] = []
        let hundreds = number / 100
        let ten = (number / 10) % 10
        let one = number % 10
        if hundreds == 1 {
            parts.append("yuz")
        } else if hundreds > 1 {
            parts.append(ones[hundreds] + " yuz")
        }
        if ten > 0 { parts.append(tens[ten]) }
        if one > 0 { parts.append(ones[one]) }
        return parts.joined(separator: " ")
    }

    /// "1", "5" → "bir butun o‘ndan besh"; "2", "25" → "ikki butun yuzdan yigirma besh".
    private static func spellDecimal(integer: String, fraction: String?) -> String {
        guard let value = Int(integer.prefix(9)) else { return integer }
        let whole = integer.count > 9 ? integer : spell(value)
        guard let fraction, !fraction.isEmpty else { return whole }
        let trimmed = String(fraction.prefix(2))
        guard let fractionValue = Int(trimmed) else { return whole }
        if fractionValue == 0 { return whole }
        let denominator = trimmed.count == 1 ? "o'ndan" : "yuzdan"
        return "\(whole) butun \(denominator) \(spell(fractionValue))"
    }

    /// 2 → "ikkinchi", 5 → "beshinchi", 20 → "yigirmanchi".
    static func ordinal(_ number: Int) -> String {
        let word = spell(number)
        let vowels: Set<Character> = ["a", "e", "i", "o", "u"]
        if let last = word.last, vowels.contains(last) { return word + "nchi" }
        return word + "inchi"
    }

    // MARK: Units

    private static func unitWord(_ word: String, next: Token?, nextNext: Token?) -> (text: String, consumed: Int)? {
        let lower = word.lowercased()
        if lower == "km", case .other("/")? = next, case .word(let w)? = nextNext,
           ["soat", "s", "h"].contains(w.lowercased()) {
            return ("kilometr soatiga", 3)
        }
        switch lower {
        case "km": return ("kilometr", 1)
        case "m": return ("metr", 1)
        case "sek", "soniya": return (word, 1)
        default: return nil
        }
    }

    // MARK: Tokenizer

    private enum Token: Equatable {
        case number(String, String?)
        case word(String)
        case other(String)
    }

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isASCII && c.isNumber {
                var integer = ""
                while i < chars.count, chars[i].isASCII, chars[i].isNumber { integer.append(chars[i]); i += 1 }
                var fraction: String?
                if i + 1 < chars.count, chars[i] == "." || chars[i] == ",", chars[i + 1].isASCII, chars[i + 1].isNumber {
                    i += 1
                    var digits = ""
                    while i < chars.count, chars[i].isASCII, chars[i].isNumber { digits.append(chars[i]); i += 1 }
                    fraction = digits
                }
                tokens.append(.number(integer, fraction))
            } else if c.isLetter || c == "'" {
                var word = ""
                while i < chars.count, chars[i].isLetter || (chars[i] == "'" && !word.isEmpty) { word.append(chars[i]); i += 1 }
                if word.isEmpty { word.append(c); i += 1 }
                tokens.append(.word(word))
            } else {
                tokens.append(.other(String(c)))
                i += 1
            }
        }
        return tokens
    }

    // MARK: Transliteration

    private static let apostrophes: Set<Character> = ["‘", "’", "ʻ", "ʼ", "`", "´", "ʹ", "′"]

    private static func normalizeApostrophes(_ text: String) -> String {
        String(text.map { apostrophes.contains($0) ? "'" : $0 })
    }

    private struct Rule {
        let pattern: String     // lowercase Latin, may contain "'"
        let lower: String
        let upper: String?      // nil → `lower` with the first letter capitalized
    }

    private static func rule(_ pattern: String, _ lower: String, _ upper: String? = nil) -> Rule {
        Rule(pattern: pattern, lower: lower, upper: upper)
    }

    /// Longest patterns first.
    private static let turkishRules: [Rule] = [
        rule("s'h", "sh"),
        rule("o'", "o"), rule("g'", "g"),
        rule("sh", "ş", "Ş"), rule("ch", "ç", "Ç"),
        rule("c", "s"), rule("j", "c"), rule("q", "k"), rule("x", "h"), rule("w", "v"),
        rule("i", "i", "İ"),
        rule("'", ""),
    ]

    private static let cyrillicRules: [Rule] = [
        rule("s'h", "сх"),
        rule("o'", "о"), rule("g'", "г"),
        rule("sh", "ш"), rule("ch", "ч"), rule("ng", "нг"),
        rule("ya", "я"), rule("yo", "ё"), rule("yu", "ю"), rule("ye", "е"),
        rule("a", "а"), rule("b", "б"), rule("c", "с"), rule("d", "д"), rule("e", "е"), rule("f", "ф"),
        rule("g", "г"), rule("h", "х"), rule("i", "и"), rule("j", "дж"), rule("k", "к"), rule("l", "л"),
        rule("m", "м"), rule("n", "н"), rule("o", "о"), rule("p", "п"), rule("q", "к"), rule("r", "р"),
        rule("s", "с"), rule("t", "т"), rule("u", "у"), rule("v", "в"), rule("w", "в"), rule("x", "х"),
        rule("y", "й"), rule("z", "з"),
        rule("'", ""),
    ]

    private static func transliterate(_ text: String, rules: [Rule], wordInitialE: String?) -> String {
        let chars = Array(text)
        var output = ""
        var i = 0
        while i < chars.count {
            var matched = false
            for rule in rules {
                let pattern = Array(rule.pattern)
                guard i + pattern.count <= chars.count else { continue }
                var ok = true
                for (offset, p) in pattern.enumerated() where chars[i + offset].lowercased() != String(p) {
                    ok = false
                    break
                }
                guard ok else { continue }
                let isUpper = chars[i].isUppercase
                var replacement = rule.lower
                if rule.pattern == "e", let wordInitialE, i == 0 || !chars[i - 1].isLetter {
                    replacement = wordInitialE
                }
                if isUpper {
                    replacement = rule.upper ?? (replacement.prefix(1).uppercased() + replacement.dropFirst())
                }
                output += replacement
                i += pattern.count
                matched = true
                break
            }
            if !matched {
                output.append(chars[i])
                i += 1
            }
        }
        return output
    }
}
