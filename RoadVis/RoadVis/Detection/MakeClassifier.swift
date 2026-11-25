import CoreML
import Foundation
import Vision

/// Optional vehicle make (brand) classifier: `VehicleMakeClassifier.mlmodelc` in the app bundle.
///
/// Runs a Core ML image classifier on crops of confirmed car/truck/bus tracks (Vision `regionOfInterest`,
/// `.centerCrop`) and returns top-1 make observations, which the tracker turns into a per-track majority vote.
///
/// Scheduling keeps the cost bounded: only boxes at least 12 % of the frame high and 10 % wide, at most two
/// classifications per frame, and each track at most every 0.6 s (never-classified tracks first).
///
/// Not thread-safe: use it on the recognition queue only.
final class MakeClassifier {
    /// Bundle resource name (`.mlmodelc`).
    static let modelResourceName = "VehicleMakeClassifier"

    /// One classification result for a track.
    struct Observation: Hashable, Sendable {
        let trackID: Int
        let make: String
        let confidence: Double
    }

    /// Scheduling limits.
    static let eligibleKinds: Set<VehicleKind> = [.car, .truck, .bus]
    static let minBoxHeight = 0.12
    static let minBoxWidth = 0.10
    static let maxPerFrame = 2
    static let minInterval: TimeInterval = 0.6
    /// Crops are enlarged by this fraction to include the whole grille/badge.
    static let cropEnlargement = 0.05
    /// Top-1 results below this confidence are ignored (too noisy to vote with).
    static let minObservationConfidence = 0.15

    private(set) var status: ModelStatus = .loading
    private var requests: [VNCoreMLRequest] = []
    private var lastClassified: [Int: TimeInterval] = [:]

    // MARK: - Loading

    @discardableResult
    func load(bundle: Bundle = .main) -> ModelStatus {
        if status.isReady { return status }
        guard let url = bundle.url(forResource: Self.modelResourceName, withExtension: "mlmodelc") else {
            status = .missing
            return status
        }
        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            let model = try MLModel(contentsOf: url, configuration: configuration)
            let vnModel = try VNCoreMLModel(for: model)
            requests = (0..<Self.maxPerFrame).map { _ in
                let request = VNCoreMLRequest(model: vnModel)
                request.imageCropAndScaleOption = .centerCrop
                return request
            }
            status = .ready(Self.modelResourceName)
        } catch {
            status = .failed(error.localizedDescription)
        }
        return status
    }

    /// Forgets the per-track schedule (call when the tracker is reset).
    func reset() {
        lastClassified.removeAll()
    }

    // MARK: - Classification

    /// Picks up to `maxPerFrame` eligible tracks, classifies their crops on the frame behind `handler`
    /// and returns the make observations (feed them to `ObjectTracker.addMakeObservation`).
    func classify(tracks: [TrackedObject], handler: VNImageRequestHandler, timestamp: TimeInterval) -> [Observation] {
        guard status.isReady, !requests.isEmpty else { return [] }
        pruneSchedule(now: timestamp, visible: tracks)

        let candidates = tracks
            .filter { track in
                track.isConfirmed && track.missed == 0 && Self.eligibleKinds.contains(track.kind)
                    && track.box.height >= Self.minBoxHeight && track.box.width >= Self.minBoxWidth
                    && timestamp - (lastClassified[track.id] ?? -.infinity) >= Self.minInterval
            }
            .sorted { a, b in
                let la = lastClassified[a.id], lb = lastClassified[b.id]
                switch (la, lb) {
                case (nil, nil): return a.box.area > b.box.area
                case (nil, _): return true
                case (_, nil): return false
                case let (ta?, tb?): return ta == tb ? a.box.area > b.box.area : ta < tb
                }
            }
            .prefix(min(Self.maxPerFrame, requests.count))
        guard !candidates.isEmpty else { return [] }

        var scheduled: [(trackID: Int, request: VNCoreMLRequest)] = []
        for (index, track) in candidates.enumerated() {
            let request = requests[index]
            request.regionOfInterest = Self.regionOfInterest(for: track.box)
            scheduled.append((track.id, request))
            lastClassified[track.id] = timestamp
        }

        do {
            try handler.perform(scheduled.map(\.request))
        } catch {
            return []
        }

        var observations: [Observation] = []
        for item in scheduled {
            let classes = (item.request.results ?? []).compactMap { $0 as? VNClassificationObservation }
            guard let best = classes.max(by: { $0.confidence < $1.confidence }),
                  Double(best.confidence) >= Self.minObservationConfidence,
                  let make = VehicleMakeNormalizer.make(fromLabel: best.identifier) else { continue }
            observations.append(Observation(trackID: item.trackID, make: make, confidence: Double(best.confidence)))
        }
        return observations
    }

    /// Vision region of interest (normalized, bottom-left origin): the box enlarged by 5 % and clamped.
    static func regionOfInterest(for box: BBox) -> CGRect {
        let dx = box.width * cropEnlargement / 2
        let dy = box.height * cropEnlargement / 2
        let enlarged = BBox(x: box.x - dx, y: box.y - dy,
                            width: box.width * (1 + cropEnlargement),
                            height: box.height * (1 + cropEnlargement)).clamped
        guard enlarged.width > 0.01, enlarged.height > 0.01 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        return enlarged.visionRect
    }

    private func pruneSchedule(now: TimeInterval, visible: [TrackedObject]) {
        guard lastClassified.count > 64 else { return }
        let visibleIDs = Set(visible.map(\.id))
        lastClassified = lastClassified.filter { visibleIDs.contains($0.key) || now - $0.value < 5 }
    }
}

/// Turns classifier labels into a make (brand) name.
///
/// Handles Stanford-Cars style labels ("AM General Hummer SUV 2000", "Land Rover Range Rover SUV 2012",
/// "Ram C/V Cargo Van Minivan 2012"), year-first labels ("2012 Tesla Model S"), snake case ("chevrolet_cobalt")
/// and common Uzbek/CIS market brands (Chevrolet, Daewoo, Ravon, BYD, Chery, Kia, Hyundai, Lada…).
enum VehicleMakeNormalizer {
    /// Multi-word makes, matched on the lower-cased leading tokens (longest first).
    private static let multiWordMakes: [([String], String)] = [
        (["lynk", "&", "co"], "Lynk & Co"),
        (["land", "rover"], "Land Rover"),
        (["aston", "martin"], "Aston Martin"),
        (["alfa", "romeo"], "Alfa Romeo"),
        (["rolls", "royce"], "Rolls-Royce"),
        (["mercedes", "benz"], "Mercedes-Benz"),
        (["am", "general"], "AM General"),
        (["ram", "c/v"], "Ram"),
        (["great", "wall"], "Great Wall"),
        (["li", "auto"], "Li Auto"),
        (["lynk", "co"], "Lynk & Co"),
        (["dong", "feng"], "Dongfeng"),
        (["mini", "cooper"], "Mini"),
    ]

    /// Canonical spelling of single-token makes and common aliases (keys are lower-cased).
    private static let canonicalNames: [String: String] = [
        "acura": "Acura", "audi": "Audi", "bentley": "Bentley", "bmw": "BMW", "bugatti": "Bugatti",
        "buick": "Buick", "byd": "BYD", "cadillac": "Cadillac", "changan": "Changan", "chery": "Chery",
        "chevrolet": "Chevrolet", "chevy": "Chevrolet", "chrysler": "Chrysler", "citroen": "Citroën",
        "citroën": "Citroën", "daewoo": "Daewoo", "dodge": "Dodge", "dongfeng": "Dongfeng", "exeed": "Exeed",
        "faw": "FAW", "ferrari": "Ferrari", "fiat": "Fiat", "fisker": "Fisker", "ford": "Ford", "gaz": "GAZ",
        "geely": "Geely", "genesis": "Genesis", "gmc": "GMC", "haval": "Haval", "honda": "Honda",
        "hongqi": "Hongqi", "hummer": "Hummer", "hyundai": "Hyundai", "infiniti": "Infiniti", "isuzu": "Isuzu",
        "jac": "JAC", "jaguar": "Jaguar", "jeep": "Jeep", "jetour": "Jetour", "kamaz": "KAMAZ", "kia": "Kia",
        "lada": "Lada", "vaz": "Lada", "lamborghini": "Lamborghini", "lexus": "Lexus", "lincoln": "Lincoln",
        "lotus": "Lotus", "man": "MAN", "maserati": "Maserati", "maybach": "Maybach", "mazda": "Mazda",
        "mclaren": "McLaren", "mercedes": "Mercedes-Benz", "mercedes-benz": "Mercedes-Benz",
        "mercedesbenz": "Mercedes-Benz", "mg": "MG", "mini": "Mini", "mitsubishi": "Mitsubishi",
        "nissan": "Nissan", "opel": "Opel", "peugeot": "Peugeot", "porsche": "Porsche", "ram": "Ram",
        "ravon": "Ravon", "renault": "Renault", "rolls-royce": "Rolls-Royce", "scania": "Scania",
        "scion": "Scion", "seat": "SEAT", "skoda": "Škoda", "škoda": "Škoda", "smart": "Smart",
        "spyker": "Spyker", "subaru": "Subaru", "suzuki": "Suzuki", "tesla": "Tesla", "toyota": "Toyota",
        "uaz": "UAZ", "volkswagen": "Volkswagen", "vw": "Volkswagen", "volvo": "Volvo", "zeekr": "Zeekr",
        "isuzu-samarkand": "Isuzu", "samauto": "SamAuto", "tata": "Tata", "foton": "Foton",
        "kaiyi": "Kaiyi", "omoda": "Omoda", "tank": "Tank", "voyah": "Voyah", "lixiang": "Li Auto",
        "nio": "NIO", "xpeng": "XPeng", "gac": "GAC", "baic": "BAIC", "jmc": "JMC", "howo": "HOWO",
        "shacman": "Shacman", "yutong": "Yutong", "iveco": "Iveco", "daf": "DAF",
    ]

    /// Make name for a classifier label, or nil when the label is empty.
    static func make(fromLabel label: String) -> String? {
        let cleaned = label
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var tokens = cleaned.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        if let first = tokens.first, first.count == 4, let year = Int(first), (1900...2100).contains(year) {
            tokens.removeFirst()
        }
        guard let firstToken = tokens.first else { return nil }
        let lowered = tokens.map { $0.lowercased() }

        for (words, display) in multiWordMakes where lowered.count >= words.count {
            if Array(lowered.prefix(words.count)) == words {
                return display
            }
        }
        if let canonical = canonicalNames[lowered[0]] {
            return canonical
        }
        // Unknown brand: keep the first token, capitalize its first letter (keeps "BMW"-style acronyms intact).
        guard let initial = firstToken.first, initial.isLetter || initial.isNumber else { return nil }
        return initial.uppercased() + firstToken.dropFirst()
    }
}
