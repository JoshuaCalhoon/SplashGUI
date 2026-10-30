import Foundation

// How the app decides which engine build to run.
enum EngineMode: String, Codable, Equatable {
    case pinned   // the build this SplashGUI shipped with (EngineInstaller.defaultPin)
    case latest   // newest GitHub release, checked on every start; falls back below
    case custom   // the three override fields (AppConfig.enginePinOverride)
}

// Resolves the newest Splash engine release from GitHub so "always latest" can install a
// build this app never shipped with. The checksum comes from the release's own .sha256
// asset and is verified by EngineInstaller exactly like the compiled-in pin; HTTPS plus
// that digest is the same trust the published release gives the pin at review time.
// Every failure — offline, rate-limited, unexpected payload — returns nil and the caller
// falls back, so this can never block Start.
struct EngineResolver {
    static let repo = "incoai/splash"
    static var latestAPI: String { "https://api.github.com/repos/\(repo)/releases/latest" }

    // The release tag as an engine version: GitHub download paths use the tag, the payload
    // names the version; today they are the same string ("1.5.0"), but a future "v" prefix
    // must not leak into the version or the file name.
    static func version(tagName: String) -> String {
        tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
    }

    static func assetFile(version: String) -> String {
        "splash-\(version)-arm64-macos26.tar.gz"
    }

    // The pure half, so the harness can feed it a fixture instead of the network: a
    // release's tag, asset names, and .sha256 text become an EnginePin — or nil when the
    // expected payload is not there. The URL is built exactly like EngineInstaller's
    // defaultPin so a latest equal to the compiled-in pin reuses its install directory.
    static func pin(tagName: String, assetNames: [String], sha256Text: String) -> EnginePin? {
        let v = version(tagName: tagName)
        let file = assetFile(version: v)
        guard assetNames.contains(file), assetNames.contains(file + ".sha256") else { return nil }
        let sha = sha256Text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard sha.count == 64, sha.allSatisfy(\.isHexDigit) else { return nil }
        return EnginePin(version: v, sha256: sha,
                         url: "https://github.com/\(repo)/releases/download/\(tagName)/\(file)")
    }

    // The live half: GET /releases/latest, then the .sha256 asset (a ~70-byte text file).
    // Anonymous GitHub API is capped at 60 requests/hour/IP — one per Start is far under.
    static func latest() async -> EnginePin? {
        guard let release = try? await fetchJSON(latestAPI),
              let tag = release["tag_name"] as? String,
              let assets = release["assets"] as? [[String: Any]] else { return nil }
        let names = assets.compactMap { $0["name"] as? String }
        let file = assetFile(version: version(tagName: tag)) + ".sha256"
        guard names.contains(file),
              let text = try? await fetchText(
                  "https://github.com/\(repo)/releases/download/\(tag)/\(file)") else { return nil }
        return pin(tagName: tag, assetNames: names, sha256Text: text)
    }

    private static func request(_ url: String) -> URLRequest? {
        guard let u = URL(string: url) else { return nil }
        var r = URLRequest(url: u, timeoutInterval: 15)
        // The API serves versioned JSON without this only by default; pin it so a media-type
        // change cannot rename tag_name/assets under us.
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        return r
    }

    private static func fetchJSON(_ url: String) async throws -> [String: Any] {
        guard let r = request(url) else { throw URLError(.badURL) }
        let (data, resp) = try await URLSession.shared.data(for: r)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.badServerResponse)
        }
        return obj
    }

    private static func fetchText(_ url: String) async throws -> String {
        guard let r = request(url) else { throw URLError(.badURL) }
        let (data, resp) = try await URLSession.shared.data(for: r)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8) else {
            throw URLError(.badServerResponse)
        }
        return text
    }
}
