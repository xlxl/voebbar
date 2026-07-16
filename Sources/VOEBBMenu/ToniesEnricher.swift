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
final class ToniesEnricher {
    static let shared = ToniesEnricher()
    private init() {}

    private let graphqlURL = "https://api.prod.tcs.toys/v2/graphql"
    private let userAgent = ADISForm.userAgent

    // MARK: - Orchestration

    func enrichMissing() async {
        let targets = ArchiveStore.shared.toniesNeedingImage()
        guard !targets.isEmpty, ToniesAuth.isConnected else { return }
        guard let token = await ToniesAuth.freshAccessToken() else { return } // not/no-longer connected
        guard let tonies = await fetchCollection(accessToken: token), !tonies.isEmpty else { return }

        try? FileManager.default.createDirectory(at: ArchiveStore.coversDirectory, withIntermediateDirectories: true)

        EnrichmentProgress.shared.start(phase: "Tonie-Bilder", total: targets.count)

        for target in targets {
            defer { EnrichmentProgress.shared.step() }
            guard let match = bestMatch(for: target.title, in: tonies) else { continue }
            guard let path = await downloadImage(match.imageUrl, mediaNumber: target.mediaNumber) else { continue }
            ArchiveStore.shared.upsertToniImage(mediaNumber: target.mediaNumber, coverPath: path)
        }
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

    // MARK: - Matching

    /// Best-scoring Tonie whose tokens are sufficiently covered by the VÖBB title, or nil.
    private func bestMatch(for voebbTitle: String, in tonies: [Tonie]) -> Tonie? {
        let haystack = Self.tokens(voebbTitle)
        guard !haystack.isEmpty else { return nil }

        var best: (tonie: Tonie, score: Double)?
        for tonie in tonies {
            let seriesTokens = Self.tokens(tonie.series)
            let titleTokens = Self.tokens(tonie.title)
            let all = seriesTokens.union(titleTokens)
            guard all.count >= 2 else { continue }

            let covered = all.intersection(haystack).count
            let coverage = Double(covered) / Double(all.count)
            // The series is the disambiguator (many episodes share generic words). Require most of
            // it to be present, and strong overall coverage, and ≥2 absolute matched tokens.
            let seriesCoverage = seriesTokens.isEmpty ? 1.0
                : Double(seriesTokens.intersection(haystack).count) / Double(seriesTokens.count)
            guard covered >= 2, coverage >= 0.7, seriesCoverage >= 0.6 else { continue }

            if best == nil || coverage > best!.score {
                best = (tonie, coverage)
            }
        }
        return best?.tonie
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
        return fileURL.path
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
