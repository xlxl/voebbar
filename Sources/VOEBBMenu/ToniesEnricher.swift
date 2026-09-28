import Foundation
import ImageIO
import CoreImage
import Vision

/// Fills cover images for borrowed **Tonies** (and CD/Hörbuch items that are actually Tonies) from
/// the my.tonies.com collection — a clean JSON GraphQL API, unlike the VÖBB HTML scraping.
///
/// The Tonie chip id has nothing to do with the VÖBB barcode, so the only join is the **title**,
/// which is formatted very differently on each side (VÖBB carries series + episode in one long
/// string; tonies.com splits them into `series.name` + `title`). We fuzzy-match on shared tokens and
/// only accept a confident hit — a wrong image is worse than none.
///
/// Politeness: at most **one** GraphQL call per refresh, and only when there is an unmatched
/// candidate and a Tonies login exists. Candidates that don't match are *not* locked as notfound —
/// a borrowed Tonie may simply not have been on the box yet and can match on a later run.
///
/// **Fallback: the public shop catalog.** A Tonie that never stood on the family's box is not in the
/// collection. For those (only items typed Tonie — a real CD must not get a Tonie figure), we match
/// against the full tonies.com shop catalog, which includes discontinued Tonies. Its search endpoint
/// is useless for this (words are OR-ed and ranked by sales, the right Tonie rarely makes the top
/// 10), so we page through the whole `tonies` category instead (~600 items, 3 requests, ~5 MB) —
/// at most once per `shopCatalogInterval`, and only while an unmatched Tonie remains.
final class ToniesEnricher {
    static let shared = ToniesEnricher()
    private init() {}

    private let graphqlURL = "https://api.prod.tcs.toys/v2/graphql"
    private let shopProductsURL = "https://api.prod.shop.tonies.com/api/os/products/"
    private let userAgent = ADISForm.userAgent

    private let shopCatalogInterval: TimeInterval = 24 * 60 * 60
    private let shopCatalogFetchedKey = "toniesShopCatalogFetchedAt"

    // MARK: - Orchestration

    func enrichMissing() async {
        var targets = ArchiveStore.shared.toniesNeedingImage()
        guard !targets.isEmpty else { return }

        try? FileManager.default.createDirectory(at: ArchiveStore.coversDirectory, withIntermediateDirectories: true)

        if ToniesAuth.isConnected,
           let token = await ToniesAuth.freshAccessToken(),   // nil: not/no-longer connected
           let tonies = await fetchCollection(accessToken: token), !tonies.isEmpty {
            targets = await fill(targets, from: tonies, phase: "Tonie-Bilder")
        }

        targets = targets.filter(\.isTonie)
        guard !targets.isEmpty, shopCatalogDue() else { return }
        guard let catalog = await fetchShopCatalog() else { return }
        UserDefaults.standard.set(Date(), forKey: shopCatalogFetchedKey)
        _ = await fill(targets, from: catalog, phase: "Tonie-Bilder (Shop)")
    }

    /// Matches each target against `tonies`, stores the image of every hit and returns the targets
    /// that stayed unmatched.
    private func fill(_ targets: [ArchiveStore.EnrichTarget], from tonies: [Tonie], phase: String) async -> [ArchiveStore.EnrichTarget] {
        EnrichmentProgress.shared.start(phase: phase, total: targets.count)
        var unmatched: [ArchiveStore.EnrichTarget] = []
        for target in targets {
            defer { EnrichmentProgress.shared.step() }
            guard let match = Self.bestMatch(for: target.title, in: tonies),
                  let path = await downloadImage(match.imageUrl, mediaNumber: target.mediaNumber) else {
                unmatched.append(target)
                continue
            }
            ArchiveStore.shared.upsertToniImage(mediaNumber: target.mediaNumber, coverPath: path)
        }
        return unmatched
    }

    private func shopCatalogDue() -> Bool {
        guard let last = UserDefaults.standard.object(forKey: shopCatalogFetchedKey) as? Date else { return true }
        return Date().timeIntervalSince(last) >= shopCatalogInterval
    }

    // MARK: - Collection (GraphQL)

    struct Tonie { let title: String; let series: String; let imageUrl: String }

    private static let contentToniesQuery = """
    query ContentTonies { households { id contentTonies { id title series { name } imageUrl } } }
    """

    private func fetchCollection(accessToken: String) async -> [Tonie]? {
        var req = URLRequest(url: URL(string: graphqlURL)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("https://my.tonies.com", forHTTPHeaderField: "Origin")
        req.setValue("https://my.tonies.com/", forHTTPHeaderField: "Referer")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "operationName": "ContentTonies",
            "query": Self.contentToniesQuery,
            "variables": [:],
        ])

        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let households = dataObj["households"] as? [[String: Any]] else {
            return nil
        }

        var out: [Tonie] = []
        for household in households {
            for ct in (household["contentTonies"] as? [[String: Any]]) ?? [] {
                let title = ct["title"] as? String ?? ""
                let series = (ct["series"] as? [String: Any])?["name"] as? String ?? ""
                let imageUrl = ct["imageUrl"] as? String ?? ""
                guard !imageUrl.isEmpty else { continue }
                out.append(Tonie(title: title, series: series, imageUrl: imageUrl))
            }
        }
        return out
    }

    // MARK: - Shop catalog (public, no login)

    /// Every Tonie in the German shop, discontinued ones included (no `endOfLife` filter), paged
    /// 200 at a time. Nil if any page fails — a partial catalog would just retry tomorrow anyway.
    private func fetchShopCatalog() async -> [Tonie]? {
        let pageSize = 200
        var out: [Tonie] = []
        for page in 0..<10 {   // hard cap; today the category needs 3 pages
            var comps = URLComponents(string: shopProductsURL)!
            comps.queryItems = [
                .init(name: "shopLocale", value: "de-DE"),
                .init(name: "categoryKey", value: "tonies"),
                .init(name: "limit", value: String(pageSize)),
                .init(name: "offset", value: String(page * pageSize)),
            ]
            var req = URLRequest(url: comps.url!)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("https://tonies.com", forHTTPHeaderField: "Origin")
            guard let (data, response) = try? await URLSession.shared.data(for: req),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let docs = json["documents"] as? [[String: Any]] else {
                return nil
            }
            for doc in docs {
                let images = (doc["images"] as? [[String: Any]]) ?? []
                // `hero-2` is the figure alone on a transparent background (what my.tonies.com
                // shows); `hero-1` adds the booklet next to it. A few products carry descriptive
                // labels instead of `hero-*`, but keep the same order.
                let figure = images.first { $0["label"] as? String == "hero-2" }
                    ?? (images.count > 1 ? images[1] : images.first)
                guard let imageUrl = figure?["url"] as? String, !imageUrl.isEmpty else { continue }
                out.append(Tonie(title: doc["name"] as? String ?? "",
                                 series: (doc["series"] as? [String: Any])?["name"] as? String ?? "",
                                 imageUrl: imageUrl))
            }
            if docs.count < pageSize { return out }
        }
        return out
    }

    // MARK: - Matching

    /// Best-scoring Tonie whose tokens are sufficiently covered by the VÖBB title, or nil.
    static func bestMatch(for voebbTitle: String, in tonies: [Tonie]) -> Tonie? {
        let haystack = Self.tokens(voebbTitle)
        guard !haystack.isEmpty else { return nil }

        var best: (tonie: Tonie, score: Double)?
        for tonie in tonies {
            let seriesTokens = Self.tokens(tonie.series)
            for title in Self.titleVariants(tonie.title) {
                guard let score = Self.score(series: seriesTokens, title: Self.tokens(title), in: haystack) else { continue }
                if best == nil || score > best!.score {
                    best = (tonie, score)
                }
            }
        }
        return best?.tonie
    }

    /// Coverage score of one Tonie title variant against the VÖBB tokens, or nil if not confident.
    static func score(series: Set<String>, title: Set<String>, in haystack: Set<String>) -> Double? {
        let all = series.union(title)
        guard all.count >= 2 else { return nil }

        let covered = all.intersection(haystack).count
        let coverage = Double(covered) / Double(all.count)
        // The series is the disambiguator (many episodes share generic words). Require most of
        // it to be present, and strong overall coverage, and ≥2 absolute matched tokens.
        let seriesCoverage = series.isEmpty ? 1.0
            : Double(series.intersection(haystack).count) / Double(series.count)
        if covered >= 2, coverage >= 0.7, seriesCoverage >= 0.6 { return coverage }

        // VÖBB often catalogues only the episode ("Der Tag, an dem Michel besonders nett sein
        // wollte") without the series tonies.com puts in front ("Michel aus Lönneberga"). An episode
        // title of ≥3 significant words that is present word for word is distinctive on its own.
        let episode = title.subtracting(series)
        if episode.count >= 3, episode.isSubset(of: haystack) { return coverage }
        return nil
    }

    /// The tonies.com title plus the variants VÖBB is likely to use instead: edition notes in
    /// parentheses dropped ("Der kleine Wassermann (Neuauflage 2022)"), and each story of a
    /// two-story Tonie on its own ("Räuber Ratte/Superwurm" — VÖBB lists only "Räuber Ratte").
    static func titleVariants(_ title: String) -> [String] {
        let bare = title.replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
        let parts = bare.components(separatedBy: "/")
        return parts.count > 1 ? [bare] + parts : [bare]
    }

    private static let stopwords: Set<String> = [
        "der", "die", "das", "und", "den", "dem", "des", "ein", "eine", "einen", "zur", "zum",
        "auf", "von", "mit", "für", "aus", "the", "and", "als", "bei", "ist", "sein", "seine",
    ]

    /// Significant lowercased tokens: split on non-alphanumerics (keeps umlaut words intact), drop
    /// stopwords and very short fragments (`&`, `3`, `du`, …) that carry no matching signal.
    /// Apostrophes are removed *before* splitting so a genitive-s lines up across sources
    /// (tonies.com `Leo's` → `leos` = VÖBB's `Leos`, instead of splitting into `leo` + `s`).
    static func tokens(_ s: String) -> Set<String> {
        let cleaned = s.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
        let parts = cleaned.components(separatedBy: CharacterSet.alphanumerics.inverted)
        return Set(parts.filter { $0.count >= 3 && !stopwords.contains($0) && !$0.allSatisfy(\.isNumber) })
    }

    // MARK: - Image download

    /// Downloads the public 530×530 Tonie PNG into `covers/{media_number}.jpg` (extension is
    /// irrelevant — the archive app decodes by content). Returns nil on any non-image response.
    private func downloadImage(_ urlString: String, mediaNumber: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://my.tonies.com/", forHTTPHeaderField: "Referer")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              (http.value(forHTTPHeaderField: "Content-Type") ?? "").hasPrefix("image/"),
              !data.isEmpty else {
            return nil
        }
        let fileURL = ArchiveStore.coversDirectory.appendingPathComponent("\(mediaNumber).jpg")
        do { try data.write(to: fileURL) } catch { return nil }
        removeBackgroundIfFlattened(at: fileURL)
        squareToMyToniesFrame(at: fileURL)
        return fileURL.path
    }

    /// my.tonies.com images are 530×530 with the figure centred and filling ~87 % of the longer
    /// side; the shop's are 1200×900 with the figure small in the middle. Re-frame any non-square
    /// transparent image to the my.tonies look — crop to the figure's alpha bounds, centre it on a
    /// transparent square — so all Tonie covers line up in the archive app. In place, best-effort:
    /// square images (all my.tonies ones) and any failure leave the file untouched.
    static let squareSide = 530
    static let figureFill = 0.87

    func squareToMyToniesFrame(at fileURL: URL) {
        guard let src = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
              cg.width != cg.height,
              let bounds = Self.opaqueBounds(of: cg),
              let figure = cg.cropping(to: bounds) else { return }

        let side = Self.squareSide
        let scale = Double(side) * Self.figureFill / Double(max(bounds.width, bounds.height))
        let w = Double(bounds.width) * scale, h = Double(bounds.height) * scale
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.interpolationQuality = .high
        ctx.draw(figure, in: CGRect(x: (Double(side) - w) / 2, y: (Double(side) - h) / 2, width: w, height: h))
        guard let out = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(fileURL as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, out, nil)
        CGImageDestinationFinalize(dest)
    }

    /// Bounding box (in `cg`'s top-left pixel coordinates, as `cropping(to:)` expects) of all pixels
    /// that aren't (nearly) transparent, or nil for an opaque or empty image.
    private static func opaqueBounds(of cg: CGImage) -> CGRect? {
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        var minX = w, minY = h, maxX = -1, maxY = -1, transparent = false
        for y in 0..<h {
            for x in 0..<w {
                if pixels[(y * w + x) * 4 + 3] > 16 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                } else {
                    transparent = true
                }
            }
        }
        guard transparent, maxX >= 0 else { return nil }   // opaque photo: nothing to crop to
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Most Tonie renders from my.tonies.com already have a transparent background, but a few ship as
    /// a flattened product photo on solid white (with a drop shadow). When the just-downloaded cover
    /// has no alpha channel, lift the subject with Vision so it matches the transparent ones. Applied
    /// in place, best-effort: any failure — or macOS < 14, where the API is unavailable — leaves the
    /// original file untouched.
    private func removeBackgroundIfFlattened(at fileURL: URL) {
        guard let src = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
        switch cg.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: break   // opaque → worth de-backgrounding
        default: return                                    // already transparent, leave it
        }
        guard #available(macOS 14.0, *) else { return }
        do {
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            try handler.perform([request])
            guard let result = request.results?.first else { return }
            let masked = try result.generateMaskedImage(ofInstances: result.allInstances,
                                                         from: handler, croppedToInstancesExtent: false)
            let ci = CIImage(cvPixelBuffer: masked)
            guard let outCG = CIContext().createCGImage(ci, from: ci.extent),
                  let dest = CGImageDestinationCreateWithURL(fileURL as CFURL, "public.png" as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, outCG, nil)
            CGImageDestinationFinalize(dest)
        } catch {
            // leave the original file as-is
        }
    }
}
