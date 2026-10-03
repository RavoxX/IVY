import Foundation
import IVYCore
import os
import Security

/// Turns "Billie Jean" into playable Spotify track URIs.
///
/// Sources, in order:
/// 1. **Spotify Web API** — only if the user added their own (free) client ID + secret in
///    Settings. Most accurate, and market-aware.
/// 2. **Deezer + iTunes Search** (public, no key) to find the canonical title/artist/album,
///    then **ListenBrainz** (public, no key) to map that recording to its Spotify IDs.
/// 3. **DuckDuckGo** `site:open.spotify.com/track` as a best-effort fallback.
///
/// A recording often has several regional Spotify IDs, and some aren't playable in the
/// user's country (Spotify then silently plays something else). The music tool therefore
/// plays candidates one by one and verifies the track that actually starts.
struct TrackResolver: Sendable {
    struct Metadata: Sendable, Equatable {
        var title: String
        var artist: String
        var album: String
    }

    struct Resolution: Sendable {
        var expected: Metadata?
        var uris: [String]
    }

    var credentials: SpotifyCredentials?
    var country: String = Locale.current.region?.identifier ?? "US"

    private var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.httpAdditionalHeaders = ["User-Agent": "IVY/1.0 (macOS assistant; https://github.com/RavoxX/IVY)"]
        return URLSession(configuration: configuration)
    }

    func resolve(_ query: String) async -> Resolution {
        var uris: [String] = []
        var expected: Metadata?

        if let credentials, let api = try? await spotifyAPISearch(query, credentials: credentials) {
            uris += api.uris
            expected = api.expected
        }

        async let deezer = deezerSearch(query)
        async let itunes = iTunesSearch(query)
        var metadata = dedupe((await deezer) + (await itunes))
        if expected == nil { expected = metadata.first }
        // "timber" also matches other artists' songs called Timber: stick to the top hit's artist.
        if let top = expected, !top.artist.isEmpty {
            metadata = metadata.filter { Self.artistMatches(playing: $0.artist, expected: top.artist) }
        }

        if !metadata.isEmpty, let ids = try? await listenBrainzIDs(for: metadata) {
            uris += ids.map { "spotify:track:\($0)" }
        }
        if uris.count < 2, let first = metadata.first ?? expected {
            let ids = (try? await duckDuckGoIDs("\(first.title) \(first.artist)")) ?? []
            uris += ids.map { "spotify:track:\($0)" }
        }
        var seen = Set<String>()
        uris = uris.filter { seen.insert($0).inserted }
        Log.spotify.info("Resolved \(uris.count) candidate tracks")
        return Resolution(expected: expected, uris: uris)
    }

    // MARK: - Metadata sources

    private func deezerSearch(_ query: String) async -> [Metadata] {
        var components = URLComponents(string: "https://api.deezer.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: "3")]
        guard let data = try? await session.data(from: components.url!).0,
              let items = JSONValue.parse(String(decoding: data, as: UTF8.self))?["data"]?.arrayValue else { return [] }
        return items.compactMap { item in
            guard let title = item["title"]?.stringValue, let artist = item["artist"]?["name"]?.stringValue else { return nil }
            return Metadata(title: title, artist: artist, album: item["album"]?["title"]?.stringValue ?? "")
        }
    }

    private func iTunesSearch(_ query: String) async -> [Metadata] {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: query), URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"), URLQueryItem(name: "limit", value: "3"),
            URLQueryItem(name: "country", value: country),
        ]
        guard let data = try? await session.data(from: components.url!).0,
              let items = JSONValue.parse(String(decoding: data, as: UTF8.self))?["results"]?.arrayValue else { return [] }
        return items.compactMap { item in
            guard let title = item["trackName"]?.stringValue, let artist = item["artistName"]?.stringValue else { return nil }
            return Metadata(title: title, artist: artist, album: item["collectionName"]?.stringValue ?? "")
        }
    }

    private func dedupe(_ items: [Metadata]) -> [Metadata] {
        var seen = Set<String>()
        return items.filter { seen.insert(Self.normalize($0.title) + "|" + Self.normalize($0.album)).inserted }
    }

    // MARK: - ListenBrainz

    /// Batched lookup with several spellings, because credits differ between catalogs
    /// ("Pitbull" vs "Pitbull feat. Kesha", "Album (Deluxe Version)" vs "Album").
    private func listenBrainzIDs(for metadata: [Metadata]) async throws -> [String] {
        var queries: [JSONValue] = []
        for item in metadata.prefix(4) {
            let (title, featured) = Self.splitFeaturing(item.title)
            var artists = [item.artist]
            if let featured { artists.append("\(item.artist) feat. \(featured)") }
            var releases = [Self.cleanAlbum(item.album), title]
            releases = releases.filter { !$0.isEmpty }
            for artist in artists {
                for release in Set(releases) {
                    queries.append(["artist_name": .string(artist), "release_name": .string(release), "track_name": .string(title)])
                }
            }
        }
        guard !queries.isEmpty else { return [] }
        var request = URLRequest(url: URL(string: "https://labs.api.listenbrainz.org/spotify-id-from-metadata/json")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(JSONValue.array(Array(queries.prefix(16))).jsonString().utf8)
        let (data, _) = try await session.data(for: request)
        let results = JSONValue.parse(String(decoding: data, as: UTF8.self))?.arrayValue ?? []
        return results.flatMap { $0["spotify_track_ids"]?.arrayValue?.prefix(4).compactMap(\.stringValue) ?? [] }
    }

    // MARK: - DuckDuckGo fallback

    private func duckDuckGoIDs(_ query: String) async throws -> [String] {
        var request = URLRequest(url: URL(string: "https://html.duckduckgo.com/html/")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let term = "site:open.spotify.com/track \(query)".addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        request.httpBody = Data("q=\(term)".utf8)
        let (data, _) = try await session.data(for: request)
        let html = String(decoding: data, as: UTF8.self)
        let regex = try NSRegularExpression(pattern: #"open\.spotify\.com(?:%2F|/)track(?:%2F|/)([A-Za-z0-9]{22})"#)
        var ids: [String] = []
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            if let range = Range(match.range(at: 1), in: html), !ids.contains(String(html[range])) { ids.append(String(html[range])) }
        }
        return Array(ids.prefix(4))
    }

    // MARK: - Spotify Web API (optional)

    private func spotifyAPISearch(_ query: String, credentials: SpotifyCredentials) async throws -> Resolution {
        let token = try await SpotifyTokenCache.shared.token(for: credentials, session: session)
        var components = URLComponents(string: "https://api.spotify.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query), URLQueryItem(name: "type", value: "track"),
            URLQueryItem(name: "limit", value: "5"), URLQueryItem(name: "market", value: country),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await session.data(for: request)
        let items = JSONValue.parse(String(decoding: data, as: UTF8.self))?["tracks"]?["items"]?.arrayValue ?? []
        let uris = items.compactMap { $0["uri"]?.stringValue }
        let expected = items.first.flatMap { item -> Metadata? in
            guard let title = item["name"]?.stringValue else { return nil }
            return Metadata(title: title, artist: item["artists"]?.arrayValue?.first?["name"]?.stringValue ?? "",
                            album: item["album"]?["name"]?.stringValue ?? "")
        }
        return Resolution(expected: expected, uris: uris)
    }

    // MARK: - Matching helpers

    /// "Timber (feat. Kesha)" → ("Timber", "Kesha")
    static func splitFeaturing(_ title: String) -> (String, String?) {
        guard let range = title.range(of: #"\s*[\(\[](feat\.?|ft\.?|featuring|with) ([^\)\]]+)[\)\]]"#,
                                      options: [.regularExpression, .caseInsensitive]) else { return (title, nil) }
        let inner = title[range]
        let featured = inner.replacingOccurrences(of: #"^\s*[\(\[](feat\.?|ft\.?|featuring|with) "#, with: "",
                                                  options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: CharacterSet(charactersIn: ")] "))
        return (title.replacingCharacters(in: range, with: ""), featured)
    }

    static func cleanAlbum(_ album: String) -> String {
        album.replacingOccurrences(of: #"\s*-\s*(Single|EP)$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*[\(\[][^\)\]]*(deluxe|edition|remaster|version|expanded)[^\)\]]*[\)\]]"#, with: "",
                                  options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
    }

    static func normalize(_ text: String) -> String {
        splitFeaturing(text).0.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .replacingOccurrences(of: #"\s*[\(\[].*?[\)\]]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+-\s+.*$"#, with: "", options: .regularExpression)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// "Pitbull & Kesha" matches "Pitbull"; "Inert Nave" doesn't.
    static func artistMatches(playing: String, expected: String) -> Bool {
        let lhs = normalize(playing), rhs = normalize(expected)
        guard let first = rhs.split(separator: " ").first else { return true }
        return lhs.contains(first) || rhs.contains(lhs.split(separator: " ").first ?? "")
    }

    /// Whether the track Spotify is actually playing is the song we asked for.
    static func matches(playing: String, expected: String) -> Bool {
        let lhs = normalize(playing), rhs = normalize(expected)
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        if lhs == rhs || lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs) { return true }
        let expectedWords = Set(rhs.split(separator: " "))
        let playingWords = Set(lhs.split(separator: " "))
        return Double(expectedWords.intersection(playingWords).count) / Double(max(1, expectedWords.count)) >= 0.75
    }
}

// MARK: - Spotify credentials

struct SpotifyCredentials: Sendable, Equatable {
    var clientID: String
    var clientSecret: String

    static let keychainAccount = "spotify-client-secret"

    /// Client ID from settings, secret from the Keychain. Nil unless both are set.
    static func load(settings: SettingsStore) -> SpotifyCredentials? {
        let id = settings.string(.spotifyClientID).trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, let secret = Keychain.read(account: keychainAccount), !secret.isEmpty else { return nil }
        return SpotifyCredentials(clientID: id, clientSecret: secret)
    }
}

actor SpotifyTokenCache {
    static let shared = SpotifyTokenCache()
    private var cached: (token: String, expires: Date, clientID: String)?

    func token(for credentials: SpotifyCredentials, session: URLSession) async throws -> String {
        if let cached, cached.clientID == credentials.clientID, cached.expires > Date() { return cached.token }
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        let basic = Data("\(credentials.clientID):\(credentials.clientSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("grant_type=client_credentials".utf8)
        let (data, _) = try await session.data(for: request)
        guard let json = JSONValue.parse(String(decoding: data, as: UTF8.self)),
              let token = json["access_token"]?.stringValue else {
            throw ToolError.failed("Spotify rejected the client ID/secret.")
        }
        let lifetime = json["expires_in"]?.doubleValue ?? 3600
        cached = (token, Date().addingTimeInterval(lifetime - 60), credentials.clientID)
        return token
    }
}

/// Minimal Keychain wrapper for IVY's secrets (generic passwords).
enum Keychain {
    static let service = "com.ravoxx.IVY"

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func write(_ value: String, account: String) -> OSStatus {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
        ]
        guard !value.isEmpty else {
            let status = SecItemDelete(base as CFDictionary)
            return status == errSecItemNotFound ? errSecSuccess : status
        }
        let data = Data(value.utf8)
        let updated = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard updated == errSecItemNotFound else { return updated }
        var item = base
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil)
    }
}
