import Foundation

/// One vehicle of a coach sequence, reduced to what identifies its series.
struct Carriage: Sendable, Hashable {
    /// 12-digit UIC number, e.g. "938054010021".
    var uic: String
    /// UIC country code, e.g. 80 for Germany.
    var country: Int?
    /// Series digits of the UIC number, e.g. 401.
    var model: Int?
    /// DB construction type, e.g. "Apmzf" or "DBpza" (double-deck).
    var constructionType: String?

    init(vehicleID: String?, constructionType: String?) {
        var uic = vehicleID ?? ""
        // "93805401002-1" → "938054010021"
        if uic.count >= 12, uic.prefix(11).allSatisfy(\.isNumber), uic[uic.index(uic.startIndex, offsetBy: 11)] == "-" {
            uic.remove(at: uic.index(uic.startIndex, offsetBy: 11))
        }
        self.uic = uic
        self.country = uic.count >= 12 ? Int(Self.slice(uic, 2, 2)) : nil
        self.model = vehicleID.flatMap(Self.model(fromVehicleID:))
        self.constructionType = constructionType
    }

    var isDoubleDeck: Bool { constructionType?.hasPrefix("D") ?? false }

    /// Digits 6-8 of the UIC number: "938054010021" → 401. The number may carry its check digit
    /// after a dash, and a trailing "-X" suffix.
    static func model(fromVehicleID id: String) -> Int? {
        guard let match = id.wholeMatch(of: /.{5}(.{3}).{3}-?.(?:-.)?/) else { return nil }
        return Int(match.1)
    }

    func digits(_ offset: Int, _ length: Int) -> String { Self.slice(uic, offset, length) }

    static func slice(_ string: String, _ offset: Int, _ length: Int) -> String {
        guard string.count >= offset + length else { return "" }
        let start = string.index(string.startIndex, offsetBy: offset)
        return String(string[start..<string.index(start, offsetBy: length)])
    }
}

/// Series of a trainset or train, detected from the UIC numbers of its vehicles.
///
/// Ported from `parse_model` and `%model_name` in Travel::Status::DE::DBRIS
/// (`Formation/Group.pm`, https://github.com/derf/Travel-Status-DE-DBRIS).
struct TrainModel: Sendable, Hashable {
    /// Marketing name, e.g. "ICE 3neo".
    var name: String
    /// Baureihe, e.g. "BR 408"; the same as `name` where there is nothing more specific.
    var series: String

    static let names: [String: TrainModel] = {
        let table: [String: [String]] = [
            "011": ["ICE T", "ÖBB 4011"],
            "023": ["CFL KISS", "CFL 2300"],
            "091": ["ICE L"],
            "401": ["ICE 1", "BR 401"],
            "402": ["ICE 2", "BR 402"],
            "403.S1": ["ICE 3", "BR 403, 1. Serie"],
            "403.S2": ["ICE 3", "BR 403, 2. Serie"],
            "403.R": ["ICE 3", "BR 403 Redesign"],
            "406": ["ICE 3", "BR 406"],
            "406.R": ["ICE 3", "BR 406 Redesign"],
            "407": ["ICE 3 Velaro", "BR 407"],
            "408": ["ICE 3neo", "BR 408"],
            "411.S1": ["ICE T", "BR 411, 1. Serie"],
            "411.S2": ["ICE T", "BR 411, 2. Serie"],
            "412": ["ICE 4", "BR 412"],
            "415": ["ICE T", "BR 415"],
            "420": ["BR 420"],
            "422": ["BR 422"],
            "423": ["BR 423"],
            "424": ["BR 424"],
            "425": ["BR 425"],
            "427": ["FLIRT", "BR 427"],
            "428": ["FLIRT", "BR 428"],
            "429": ["FLIRT", "BR 429"],
            "1430": ["FLIRT", "BR 1430"],
            "430": ["BR 430"],
            "1440": ["Coradia Continental", "BR 1440"],
            "440": ["Coradia Continental", "BR 440"],
            "442": ["Talent 2", "BR 442"],
            "445": ["Twindexx Vario", "BR 445"],
            "446": ["Twindexx Vario", "BR 446"],
            "445446": ["Stadler KISS", "BR 445"],
            "462": ["Desiro HC", "BR 462"],
            "463": ["Mireo", "BR 463"],
            "464": ["Mireo Smart", "BR 464"],
            "475": ["TGV", "BR 475"],
            "501": ["SMILE", "RABe 501"],
            "503": ["Astoro", "RABe 503"],
            "526": ["FLIRT Akku", "BR 526"],
            "563": ["Mireo Plus B", "BR 563"],
            "612": ["RegioSwinger", "BR 612"],
            "620": ["LINT 81", "BR 620"],
            "622": ["LINT 54", "BR 622"],
            "623": ["LINT 41", "BR 623"],
            "631": ["Link I", "BR 631"],
            "632": ["Link II", "BR 632"],
            "633": ["Link III", "BR 633"],
            "640": ["LINT 27", "BR 640"],
            "642": ["Desiro Classic", "BR 642"],
            "643": ["TALENT", "BR 643"],
            "644": ["TALENT", "BR 644"],
            "648": ["LINT 41", "BR 648"],
            "650": ["Regio-Shuttle RS1", "BR 650"],
            "IC2.TWIN": ["IC 2 Twindexx"],
            "IC2.KISS": ["IC 2 KISS"],
        ]
        return table.mapValues { TrainModel(name: $0[0], series: $0[$0.count - 1]) }
    }()

    /// The most likely series of `carriages`, or nil if the numbers are inconclusive (fewer than two
    /// vehicles agreeing, except for the single-car BR 631/640/650).
    static func detect(_ carriages: [Carriage], category: String) -> TrainModel? {
        var votes: [String: Int] = [:]
        var order: [String] = []
        for carriage in carriages {
            guard let subtype = subtype(of: carriage, category: category) else { continue }
            if votes[subtype] == nil { order.append(subtype) }
            votes[subtype, default: 0] += 1
        }
        guard let best = order.max(by: { votes[$0]! < votes[$1]! }) else { return nil }
        let singleCar = ["631", "640", "650"].contains(best) && carriages.count == 1 && carriages[0].digits(0, 2) == "95"
        guard votes[best]! >= 2 || singleCar else { return nil }
        return names[best]
    }

    static func subtype(of carriage: Carriage, category: String) -> String? {
        guard let model = carriage.model, model != 0, let country = carriage.country else { return nil }
        switch country {
        case 80: return germanSubtype(model: model, carriage: carriage, category: category)
        case 81: return carriage.digits(4, 4) == "4011" ? "011" : nil
        case 82: return model == 23 ? "023" : nil
        default: return nil
        }
    }

    private static func germanSubtype(model: Int, carriage: Carriage, category: String) -> String? {
        let serial = Int(carriage.digits(9, 2)) ?? 0
        let block = carriage.digits(5, 4)
        switch model {
        case 91, 491, 791, 891: return "091"
        case 401, 801...804: return "401"
        case 402, 805...808: return "402"
        case 403: return serial <= 37 ? "403.S1" : "403.S2"
        case 406: return "406"
        case 407: return "407"
        case 408: return "408"
        case 412, 812: return "412"
        case 411: return serial <= 32 ? "411.S1" : "411.S2"
        case 415: return "415"
        case 420, 421: return "420"
        case 422, 432: return "422"
        case 423, 433: return "423"
        case 424, 434: return "424"
        case 425, 435: return "425"
        case 427, 827: return "427"
        case 428, 828: return "428"
        case 429, 829: return "429"
        default: break
        }
        if block == "1430" || block == "1830" { return "1430" }
        if model == 430 || model == 431 { return "430" }
        if block == "1440" || block == "1441" { return "1440" }
        switch model {
        case 440, 441, 841: return "440"
        case 442, 443: return "442"
        case 462, 862: return "462"
        case 463, 863: return "463"
        case 464: return "464"
        default: break
        }
        if block.wholeMatch(of: /44[56][16]/) != nil { return "445446" }
        switch model {
        case 445: return "445"
        case 446: return "446"
        case 475: return "475"
        case 501: return "501"
        case 503, 610: return "503"
        case 526: return "526"
        case 563: return "563"
        case 612: return "612"
        case 620, 621: return "620"
        case 622: return "622"
        case 623: return "623"
        case 631: return "631"
        case 632: return "632"
        case 633: return "633"
        case 640: return "640"
        case 642: return "642"
        case 643, 943: return "643"
        case 644, 944: return "644"
        case 648: return "648"
        case 650: return "650"
        default: break
        }
        if category == "IC", model == 110 { return "IC2.KISS" }
        if category == "IC", carriage.isDoubleDeck { return "IC2.TWIN" }
        return nil
    }
}
