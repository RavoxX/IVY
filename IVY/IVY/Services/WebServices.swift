import Foundation
import IVYCore
import os

/// Background web lookup for questions the local model can't answer from memory.
///
/// Uses DuckDuckGo's HTML endpoint (no key, no account) and Wikipedia's public API as a
/// fallback, then reads several pages so the model can answer from real text. Only the
/// search query is sent; it can be switched off in Settings ▸ Integrations.
struct WebSearchService: Sendable {
    struct Result: Sendable {
        var links: [SourceLink]
        /// Source-associated page excerpts and available dates, for grounding the answer.
        var excerpt: String?
    }

    private var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 7
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            "Accept-Language": Locale.preferredLanguages.prefix(2).joined(separator: ","),
        ]
        return URLSession(configuration: configuration)
    }

    func search(_ query: String) async throws -> Result {
        var links = (try? await duckDuckGo(query)) ?? []
        if links.isEmpty { links = (try? await wikipedia(query)) ?? [] }
        guard !links.isEmpty else { throw ToolError.unavailable("I couldn't reach the web search. Check your connection.") }

        let sources = Array(links.prefix(3))
        let excerpts = await withTaskGroup(of: (Int, PageExcerpt?).self) { group in
            for (index, link) in sources.enumerated() {
                group.addTask { (index, await readableText(from: link.url)) }
            }
            var values: [(Int, PageExcerpt)] = []
            for await (index, page) in group {
                if let page, page.text.count > 200 { values.append((index, page)) }
            }
            return values.sorted { $0.0 < $1.0 }.map { index, page in
                let published = page.published.map { "\nPage-declared publication date: " + $0 } ?? ""
                return "Source: \(sources[index].url.absoluteString)\nRetrieved: \(Date().formatted(.iso8601))" + published + "\n" + String(page.text.prefix(1400))
            }
        }
        let excerpt = excerpts.isEmpty ? nil : excerpts.joined(separator: "\n\n")
        Log.tools.info("Web search returned \(links.count) results")
        return Result(links: Array(links.prefix(5)), excerpt: excerpt)
    }

    // MARK: - DuckDuckGo

    private func duckDuckGo(_ query: String) async throws -> [SourceLink] {
        var request = URLRequest(url: URL(string: "https://html.duckduckgo.com/html/")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("q=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")".utf8)
        let (data, _) = try await session.data(for: request)
        return Self.parseDuckDuckGo(String(decoding: data, as: UTF8.self))
    }

    static func parseDuckDuckGo(_ html: String) -> [SourceLink] {
        guard let linkRegex = try? NSRegularExpression(pattern: #"<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#,
                                                       options: [.dotMatchesLineSeparators]),
              let snippetRegex = try? NSRegularExpression(pattern: #"<a[^>]*class="result__snippet"[^>]*>(.*?)</a>"#,
                                                          options: [.dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        let snippets = snippetRegex.matches(in: html, range: range).compactMap { match in
            Range(match.range(at: 1), in: html).map { HTMLText.plain(String(html[$0])) }
        }
        var links: [SourceLink] = []
        for (index, match) in linkRegex.matches(in: html, range: range).enumerated() {
            guard let hrefRange = Range(match.range(at: 1), in: html), let titleRange = Range(match.range(at: 2), in: html),
                  let url = resolveRedirect(HTMLText.decodeEntities(String(html[hrefRange]))) else { continue }
            // Skip DuckDuckGo's own ads.
            if url.host?.contains("duckduckgo.com") == true { continue }
            links.append(SourceLink(title: HTMLText.plain(String(html[titleRange])), url: url,
                                    snippet: index < snippets.count ? snippets[index] : ""))
        }
        return links
    }

    /// DuckDuckGo wraps results as //duckduckgo.com/l/?uddg=<encoded target>.
    static func resolveRedirect(_ href: String) -> URL? {
        let absolute = href.hasPrefix("//") ? "https:" + href : href
        guard let components = URLComponents(string: absolute) else { return nil }
        if let target = components.queryItems?.first(where: { $0.name == "uddg" })?.value, let url = URL(string: target) {
            return url
        }
        return components.url.flatMap { ["http", "https"].contains($0.scheme ?? "") ? $0 : nil }
    }

    // MARK: - Wikipedia fallback

    private func wikipedia(_ query: String) async throws -> [SourceLink] {
        let language = Locale.current.language.languageCode?.identifier == "de" ? "de" : "en"
        var components = URLComponents(string: "https://\(language).wikipedia.org/w/api.php")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"), URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srsearch", value: query), URLQueryItem(name: "srlimit", value: "3"),
            URLQueryItem(name: "format", value: "json"),
        ]
        let (data, _) = try await session.data(from: components.url!)
        let results = JSONValue.parse(String(decoding: data, as: UTF8.self))?["query"]?["search"]?.arrayValue ?? []
        return results.compactMap { item in
            guard let title = item["title"]?.stringValue,
                  let url = URL(string: "https://\(language).wikipedia.org/wiki/\(title.replacingOccurrences(of: " ", with: "_").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")")
            else { return nil }
            return SourceLink(title: title, url: url, snippet: HTMLText.plain(item["snippet"]?.stringValue ?? ""))
        }
    }

    // MARK: - Page text

    private struct PageExcerpt: Sendable { let text: String; let published: String? }

    private func readableText(from url: URL) async -> PageExcerpt? {
        guard ["http", "https"].contains(url.scheme ?? "") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode ?? 0 < 400,
              (response.mimeType ?? "text/html").contains("html"),
              data.count < 3_000_000 else { return nil }
        let html = String(decoding: data, as: UTF8.self)
        return PageExcerpt(text: HTMLText.paragraphs(html), published: HTMLText.publicationDate(html))
    }
}

/// Tiny HTML → text helpers (no WebKit needed).
enum HTMLText {
    /// Keep declared dates separate from retrieval time; never infer a publication date.
    static func publicationDate(_ html: String) -> String? {
        let patterns = [
            #"<meta\b[^>]*(?:property|name)\s*=\s*["'](?:article:published_time|datePublished)["'][^>]*content\s*=\s*["']([^"']+)["']"#,
            #"<meta\b[^>]*content\s*=\s*["']([^"']+)["'][^>]*(?:property|name)\s*=\s*["'](?:article:published_time|datePublished)["']"#,
            #""datePublished"\s*:\s*"([^"\r\n]+)""#,
        ]
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withFullDate]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html) else { continue }
            let date = String(html[range].prefix(10))
            if date.count == 10, formatter.date(from: date) != nil { return date }
        }
        return nil
    }

    static func plain(_ html: String) -> String {
        decodeEntities(html.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Joins the page's paragraphs, which skips menus, scripts and footers reasonably well.
    static func paragraphs(_ html: String) -> String {
        var cleaned = html.replacingOccurrences(of: #"<(script|style|noscript|nav|footer|header)[^>]*>.*?</\1>"#, with: " ",
                                                options: [.regularExpression, .caseInsensitive])
        cleaned = cleaned.replacingOccurrences(of: "\n", with: " ")
        guard let regex = try? NSRegularExpression(pattern: #"<p[^>]*>(.*?)</p>"#, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return plain(cleaned)
        }
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        let parts = regex.matches(in: cleaned, range: range).compactMap { match -> String? in
            guard let r = Range(match.range(at: 1), in: cleaned) else { return nil }
            let text = plain(String(cleaned[r]))
            return text.count > 40 ? text : nil
        }
        return parts.joined(separator: "\n")
    }

    static func decodeEntities(_ text: String) -> String {
        var result = text
        let entities = ["&amp;": "&", "&quot;": "\"", "&#x27;": "'", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">",
                        "&nbsp;": " ", "&ndash;": "–", "&mdash;": "—", "&hellip;": "…"]
        for (entity, value) in entities { result = result.replacingOccurrences(of: entity, with: value) }
        if let regex = try? NSRegularExpression(pattern: #"&#(\d+);"#) {
            for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let range = Range(match.range, in: result), let codeRange = Range(match.range(at: 1), in: result),
                      let code = UInt32(result[codeRange]), let scalar = Unicode.Scalar(code) else { continue }
                result.replaceSubrange(range, with: String(Character(scalar)))
            }
        }
        return result
    }
}

/// Weather via Open-Meteo (free, no key). Without a location IVY uses the city of the
/// Mac's time zone, so no Location Services permission is needed.
struct WeatherService: Sendable {
    private var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        return URLSession(configuration: configuration)
    }

    static var defaultLocation: String {
        let identifier = TimeZone.current.identifier
        return identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? "Berlin"
    }

    func report(location rawLocation: String?, tomorrow: Bool) async throws -> WeatherReport {
        let location = rawLocation?.isEmpty == false ? rawLocation! : Self.defaultLocation
        var geocode = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        geocode.queryItems = [URLQueryItem(name: "name", value: location), URLQueryItem(name: "count", value: "1"),
                              URLQueryItem(name: "language", value: "en")]
        let (geoData, _) = try await session.data(from: geocode.url!)
        guard let place = JSONValue.parse(String(decoding: geoData, as: UTF8.self))?["results"]?.arrayValue?.first,
              let latitude = place["latitude"]?.doubleValue, let longitude = place["longitude"]?.doubleValue else {
            throw ToolError.failed("I couldn't find a place called \(location).")
        }
        let name = place["name"]?.stringValue ?? location
        let fahrenheit = Locale.current.measurementSystem == .us

        var forecast = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        forecast.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)), URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,weather_code"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            URLQueryItem(name: "timezone", value: "auto"), URLQueryItem(name: "forecast_days", value: "2"),
            URLQueryItem(name: "temperature_unit", value: fahrenheit ? "fahrenheit" : "celsius"),
        ]
        let (data, _) = try await session.data(from: forecast.url!)
        guard let json = JSONValue.parse(String(decoding: data, as: UTF8.self)), let daily = json["daily"] else {
            throw ToolError.failed("The weather service didn't respond.")
        }
        let index = tomorrow ? 1 : 0
        func dailyValue(_ key: String) -> Double? { daily[key]?.arrayValue?.dropFirst(index).first?.doubleValue }
        let code = Int(tomorrow ? (dailyValue("weather_code") ?? 0) : (json["current"]?["weather_code"]?.doubleValue ?? 0))
        let (condition, symbol) = Self.describe(code: code)
        return WeatherReport(
            location: name, day: tomorrow ? "Tomorrow" : "Today",
            temperature: tomorrow ? (dailyValue("temperature_2m_max") ?? 0) : (json["current"]?["temperature_2m"]?.doubleValue ?? 0),
            apparent: tomorrow ? nil : json["current"]?["apparent_temperature"]?.doubleValue,
            high: dailyValue("temperature_2m_max") ?? 0, low: dailyValue("temperature_2m_min") ?? 0,
            condition: condition, symbol: symbol,
            precipitationChance: dailyValue("precipitation_probability_max").map { Int($0) },
            unit: fahrenheit ? "°F" : "°C")
    }

    /// WMO weather codes → text + SF Symbol.
    static func describe(code: Int) -> (String, String) {
        switch code {
        case 0: return ("Clear", "sun.max.fill")
        case 1, 2: return ("Partly cloudy", "cloud.sun.fill")
        case 3: return ("Overcast", "cloud.fill")
        case 45, 48: return ("Fog", "cloud.fog.fill")
        case 51, 53, 55, 56, 57: return ("Drizzle", "cloud.drizzle.fill")
        case 61, 63, 65, 66, 67, 80, 81, 82: return ("Rain", "cloud.rain.fill")
        case 71, 73, 75, 77, 85, 86: return ("Snow", "cloud.snow.fill")
        case 95, 96, 99: return ("Thunderstorm", "cloud.bolt.rain.fill")
        default: return ("Mixed", "cloud.sun.fill")
        }
    }
}
