//
//  BRoll.swift
//  AnyClip
//
//  B-roll inserts: short, animated keyword cards cut into a clip. Each card is
//  drawn in code (paper collage, poster, sticker note…) from a still of the
//  speaker, so there's no stock footage and nothing to license.
//

import Foundation
import NaturalLanguage

nonisolated enum BRollKind: String, Codable, Sendable {
    /// Covers the whole frame for a moment.
    case full
    /// A smaller card placed beside the speaker.
    case overlay
}

nonisolated enum BRollStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case collage, poster, note, label, polaroid

    var id: String { rawValue }

    var kind: BRollKind {
        switch self {
        case .collage, .poster: .full
        case .note, .label, .polaroid: .overlay
        }
    }

    var name: String {
        switch self {
        case .collage: String(localized: "Collage")
        case .poster: String(localized: "Poster")
        case .note: String(localized: "Note")
        case .label: String(localized: "Label")
        case .polaroid: String(localized: "Photo")
        }
    }

    static let fullStyles: [BRollStyle] = [.collage, .poster]
    static let overlayStyles: [BRollStyle] = [.note, .label, .polaroid]
}

nonisolated struct BRollInsert: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    /// Start, in source time like caption words.
    var time: Double
    var duration: Double
    /// The big word on the card.
    var keyword: String
    /// Optional smaller words above it.
    var lead: String = ""
    var style: BRollStyle
    var palette: Int = 0

    var kind: BRollKind { style.kind }

    static let fullDuration = 3.0
    static let overlayDuration = 2.6
}

/// Colours for a card: paper background, accent, plus shared cream and ink.
nonisolated struct BRollPalette: Sendable {
    let background: String
    let accent: String

    static let cream = "#F5EEDC"
    static let ink = "#1A1714"
    static let tape = "#E9DFC4"

    static let all: [BRollPalette] = [
        BRollPalette(background: "#F4D35E", accent: "#EE4266"),
        BRollPalette(background: "#2EC4B6", accent: "#FF9F1C"),
        BRollPalette(background: "#E4572E", accent: "#FFC914"),
        BRollPalette(background: "#A0C4FF", accent: "#FF5D8F"),
        BRollPalette(background: "#CDB4DB", accent: "#3A86FF"),
        BRollPalette(background: "#B5E48C", accent: "#F15BB5"),
    ]

    static func at(_ index: Int) -> BRollPalette { all[((index % all.count) + all.count) % all.count] }
}

/// Picks the moments worth a B-roll card: words with stakes (money, fear, secrets…), numbers,
/// and the words the AI put in the clip's title and hook.
nonisolated enum BRollPlanner {
    struct Context {
        var start: Double
        var end: Double
        var title: String
        var hook: String
        /// Seconds the hook title covers at the start of the clip; cards wait until it's gone.
        var hookSeconds: Double
    }

    static func plan(words: [Word], context: Context) -> [BRollInsert] {
        let duration = context.end - context.start
        guard duration > 6 else { return [] }
        let earliest = context.start + max(1.5, context.hookSeconds + 0.4)
        let latest = context.end - BRollInsert.overlayDuration - 0.4
        guard latest > earliest else { return [] }

        let topic = Set(tokens(context.title + " " + context.hook).map(stem))
        let nouns = nounSet(words)
        var candidates: [(index: Int, score: Double)] = []
        for (i, word) in words.enumerated() where word.start >= earliest && word.start <= latest {
            let s = score(words, i, topic: topic, nouns: nouns)
            if s >= 6 { candidates.append((i, s)) }
        }
        guard !candidates.isEmpty else { return [] }

        let wanted = duration < 18 ? 1 : duration < 40 ? 2 : 3
        var picked: [(index: Int, score: Double)] = []
        var usedStems = Set<String>()
        for gap in [10.0, 7.0] {
            for c in candidates.sorted(by: { $0.score > $1.score }) where picked.count < wanted {
                let t = words[c.index].start
                let s = stem(clean(words[c.index].text))
                guard !usedStems.contains(s), !picked.contains(where: { abs(words[$0.index].start - t) < gap }) else { continue }
                picked.append(c)
                usedStems.insert(s)
            }
        }

        // The strongest moment gets the full-screen card when it fits; the rest are overlays.
        let strongest = picked.max { $0.score < $1.score }?.index
        var overlayCycle = 0
        return picked.map { c -> BRollInsert in
            let (keyword, lead) = phrase(words, c.index)
            let t = max(context.start, words[c.index].start - 0.15)
            // Mix in the time so the same word in different clips doesn't always get the same look.
            let seed = stableHash(keyword) &+ Int(t * 10)
            let canBeFull = c.index == strongest && t + BRollInsert.fullDuration <= context.end - 0.3
            let style: BRollStyle
            if canBeFull {
                style = BRollStyle.fullStyles[seed % BRollStyle.fullStyles.count]
            } else {
                style = BRollStyle.overlayStyles[(seed + overlayCycle) % BRollStyle.overlayStyles.count]
                overlayCycle += 1
            }
            return BRollInsert(time: t, duration: style.kind == .full ? BRollInsert.fullDuration : BRollInsert.overlayDuration,
                               keyword: keyword, lead: lead, style: style, palette: seed % BRollPalette.all.count)
        }
        .sorted { $0.time < $1.time }
    }

    /// One overlay card for the word nearest `time`, for "Add at Playhead".
    static func insert(at time: Double, words: [Word], context: Context) -> BRollInsert {
        let topic = Set(tokens(context.title + " " + context.hook).map(stem))
        let nouns = nounSet(words)
        let nearby = words.indices.filter { abs(words[$0].start - time) < 2 }
        let best = nearby.max { score(words, $0, topic: topic, nouns: nouns) < score(words, $1, topic: topic, nouns: nouns) }
            ?? words.indices.min { abs(words[$0].start - time) < abs(words[$1].start - time) }
        let (keyword, lead) = best.map { phrase(words, $0) } ?? (String(localized: "Keyword"), "")
        let seed = stableHash(keyword)
        let start = min(max(time, context.start), max(context.start, context.end - BRollInsert.overlayDuration))
        return BRollInsert(time: start, duration: BRollInsert.overlayDuration, keyword: keyword, lead: lead,
                           style: BRollStyle.overlayStyles[seed % BRollStyle.overlayStyles.count],
                           palette: seed % BRollPalette.all.count)
    }

    // MARK: Scoring

    private static func score(_ words: [Word], _ i: Int, topic: Set<String>, nouns: Set<String>) -> Double {
        let raw = words[i].text
        let w = clean(raw).lowercased()
        guard w.count >= 3, !stopwords.contains(w) else { return -1 }
        let s = stem(w)
        var score = min(Double(w.count), 10) * 0.4
        if stakes.contains(s) || stakes.contains(w) { score += 6 }
        if numberWords.contains(w) || w.contains(where: \.isNumber) { score += 5 }
        if topic.contains(s) { score += 7 }
        if nouns.contains(w) { score += 2 }
        if let last = raw.last, "!?".contains(last) { score += 2 }
        if w.count < 4 && !w.contains(where: \.isNumber) { score -= 2 }
        return score
    }

    /// The keyword plus up to two words that lead into it, e.g. "10 MILIAR" or "KESALAHAN" + "uang".
    private static func phrase(_ words: [Word], _ i: Int) -> (keyword: String, lead: String) {
        var keyword = clean(words[i].text)
        var j = i - 1
        // "10 miliar", "50 persen": keep the number with its unit.
        if numberWords.contains(keyword.lowercased()), j >= 0, clean(words[j].text).contains(where: \.isNumber) {
            keyword = clean(words[j].text) + " " + keyword
            j -= 1
        }
        var lead: [String] = []
        while j >= 0, lead.count < 2, i - j <= 3 {
            let text = words[j].text
            if let last = text.last, ".?!,".contains(last) { break }
            lead.insert(clean(text), at: 0)
            j -= 1
        }
        while let first = lead.first, stopwords.contains(first.lowercased()) || first.isEmpty { lead.removeFirst() }
        let leadText = lead.joined(separator: " ")
        return (keyword, leadText.lowercased() == keyword.lowercased() ? "" : leadText)
    }

    private static func nounSet(_ words: [Word]) -> Set<String> {
        let text = words.map(\.text).joined(separator: " ")
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var nouns = Set<String>()
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitPunctuation, .omitWhitespace]) { tag, range in
            if tag == .noun { nouns.insert(String(text[range]).lowercased()) }
            return true
        }
        return nouns
    }

    static func clean(_ word: String) -> String {
        String(word.unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) || $0 == "-" || $0 == "%" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map { clean(String($0)).lowercased() }.filter { $0.count >= 3 }
    }

    /// Drops common Indonesian suffixes so "utangnya" matches "utang".
    static func stem(_ word: String) -> String {
        var w = word.lowercased()
        for suffix in ["nya", "lah", "kah", "pun"] where w.count > suffix.count + 3 && w.hasSuffix(suffix) {
            w.removeLast(suffix.count)
            break
        }
        return w
    }

    static func stableHash(_ text: String) -> Int {
        var h: UInt32 = 2166136261
        for b in text.lowercased().utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return Int(h % 1_000_003)
    }

    // MARK: Word lists

    static let stopwords: Set<String> = Set("""
    yang dan di ke dari ini itu ada aku kamu gue gua lu lo elu kita kami mereka dia saya anda akan sudah udah belum bisa \
    juga aja saja kalau kalo karena karna tapi tetapi jadi untuk buat dengan sama dalam pada atau tidak nggak gak enggak \
    ngga bukan lagi banget sangat lebih paling harus mau ingin pengen punya kayak seperti gitu gini begitu begini terus \
    trus lalu kemudian sih dong deh kok nah nih tuh loh kan emang memang sebenarnya sebenernya gimana bagaimana kenapa \
    mengapa apa siapa mana kapan semua setiap banyak sedikit orang hal cara sesuatu tadi nanti sekarang masih pernah \
    sering selalu cuma hanya terlalu benar bener betul oke okay iya yaitu adalah ialah tersebut namun bahwa agar supaya \
    sampai hingga oleh para pun misalnya contohnya makanya sehingga mungkin tentunya pokoknya akhirnya ternyata langsung \
    soalnya biasanya sendiri semuanya beberapa menggunakan bilang ngomong kalian anak-anak \
    the and but for with from about are was were been being have has had does did will would can could should may \
    might must that this these those its they them their our you your his her not yes just really very like know \
    think going gonna want thing things something people because actually basically literally also then than there \
    here what when where which who why how all some any more most much many one get got make made say said well \
    right okay yeah into out over only even still back way kind sort lot
    """.split(whereSeparator: \.isWhitespace).map(String.init))

    private static let stakes: Set<String> = Set("""
    uang duit gaji utang hutang cicilan pinjol kredit tabungan nabung investasi saham kripto crypto bisnis usaha cuan \
    untung rugi modal kaya miskin bangkrut pajak harga mahal murah warisan rumah mobil properti pensiun karier karir \
    kerja kerjaan kantor bos gagal kegagalan sukses kesuksesan takut ketakutan malu bahaya berbahaya rahasia salah \
    kesalahan penting mimpi keluarga orangtua cinta nikah menikah cerai putus sehat kesehatan sakit stres depresi mental \
    bahagia sedih marah kecewa bohong jujur hidup kehidupan mati kematian waktu masa depan viral fatal hancur kehancuran \
    menghancurkan miliarder sultan jutawan budak bebas kebebasan pendidikan sekolah kuliah ilmu otak fokus disiplin \
    kebiasaan sabar ambisi gengsi gaya flexing kelas menengah inflasi resesi krisis peluang risiko target strategi \
    money debt salary rich poor broke invest investing investment stock stocks business profit loss price tax house \
    career job boss fail failure success fear danger dangerous secret mistake mistakes important dream family love \
    health stress anxiety happy sad angry truth lie life death time future power risk freedom brain focus habit habits \
    discipline growth wealth millionaire billionaire crisis opportunity strategy thinking creativity atrophy intelligence
    """.split(whereSeparator: \.isWhitespace).map(String.init))

    private static let numberWords: Set<String> = Set("""
    ribu juta miliar milyar triliun persen rupiah dolar million billion trillion thousand percent dollars
    """.split(whereSeparator: \.isWhitespace).map(String.init))
}
