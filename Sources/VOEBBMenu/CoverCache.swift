import Foundation

enum CoverCache {
    /// Downloads an image into `covers/{media_number}.jpg` (extension is irrelevant — the archive
    /// app decodes by content). Returns nil on any non-image response or write failure.
    static func download(_ urlString: String, mediaNumber: String, session: URLSession, referer: String) async -> URL? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.setValue(ADISForm.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(referer, forHTTPHeaderField: "Referer")
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              (http.value(forHTTPHeaderField: "Content-Type") ?? "").hasPrefix("image/"),
              !data.isEmpty else {
            return nil
        }
        let fileURL = ArchiveStore.coversDirectory.appendingPathComponent("\(mediaNumber).jpg")
        do { try data.write(to: fileURL); return fileURL } catch { return nil }
    }
}
