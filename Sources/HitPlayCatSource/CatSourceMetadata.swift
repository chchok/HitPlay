import Foundation

public struct CatalogMetadata: Decodable, Equatable {
    public struct Person: Decodable, Equatable, Identifiable {
        public let id: Int
        public let name: String
        public let character: String?
        public let profilePath: String?
        public let job: String?
        public let department: String?

        enum CodingKeys: String, CodingKey {
            case id, name, character, job, department
            case profilePath = "profile_path"
        }

        public var imageURL: URL? { profilePath.flatMap { URL(string: "https://image.tmdb.org/t/p/w185\($0)") } }

        public var displayRole: String {
            if let character, !character.isEmpty { return character }
            switch job?.lowercased() {
            case "director": return "导演"
            case "writer", "screenplay", "story": return "编剧"
            case "producer", "executive producer": return "制片人"
            case "editor": return "剪辑"
            case "cinematography": return "摄影"
            default: return job ?? department ?? "演员"
            }
        }
    }

    public struct Video: Decodable, Equatable, Identifiable {
        public let id: String
        public let key: String
        public let name: String
        public let site: String
        public let type: String
        public let official: Bool?

        public var youtubeURL: URL? {
            guard site.caseInsensitiveCompare("YouTube") == .orderedSame else { return nil }
            return URL(string: "https://www.youtube.com/watch?v=\(key)")
        }
        public var thumbnailURL: URL? {
            guard site.caseInsensitiveCompare("YouTube") == .orderedSame else { return nil }
            return URL(string: "https://img.youtube.com/vi/\(key)/hqdefault.jpg")
        }
    }

    public struct Recommendation: Decodable, Equatable, Identifiable {
        public let id: Int
        public let title: String?
        public let name: String?
        public let posterPath: String?
        public let overview: String?

        enum CodingKeys: String, CodingKey {
            case id, title, name, overview
            case posterPath = "poster_path"
        }

        public var displayTitle: String { title ?? name ?? "未命名" }
        public var imageURL: URL? { posterPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w500\($0)") } }
    }

    public struct Genre: Decodable, Equatable, Identifiable {
        public let id: Int
        public let name: String
    }

    public struct Credits: Decodable, Equatable {
        public let cast: [Person]?
        public let crew: [Person]?
    }

    public struct VideoPage: Decodable, Equatable {
        public let results: [Video]?
    }

    public struct RecommendationPage: Decodable, Equatable {
        public let results: [Recommendation]?
    }

    public struct ReleaseDates: Decodable, Equatable {
        public struct Country: Decodable, Equatable {
            public struct Entry: Decodable, Equatable {
                public let certification: String?
                public let note: String?
            }
            public let isoCountry: String
            public let releaseDates: [Entry]

            enum CodingKeys: String, CodingKey {
                case isoCountry = "iso_3166_1"
                case releaseDates = "release_dates"
            }
        }
        public let results: [Country]
    }

    public struct ContentRatings: Decodable, Equatable {
        public struct Country: Decodable, Equatable {
            public let isoCountry: String
            public let rating: String
            enum CodingKeys: String, CodingKey {
                case isoCountry = "iso_3166_1"
                case rating
            }
        }
        public let results: [Country]
    }

    public let overview: String?
    public let backdropPath: String?
    public let posterPath: String?
    public let voteAverage: Double?
    public let releaseDate: String?
    public let firstAirDate: String?
    public let genres: [Genre]?
    public let credits: Credits?
    public let recommendations: RecommendationPage?
    public let videos: VideoPage?
    public let releaseDates: ReleaseDates?
    public let contentRatings: ContentRatings?

    enum CodingKeys: String, CodingKey {
        case overview, genres, credits, recommendations, videos
        case releaseDates = "release_dates"
        case contentRatings = "content_ratings"
        case backdropPath = "backdrop_path"
        case posterPath = "poster_path"
        case voteAverage = "vote_average"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
    }

    public var backdropURL: URL? { backdropPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w1280\($0)") } }
    public var posterURL: URL? { posterPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w500\($0)") } }
    public var year: String? { (releaseDate ?? firstAirDate).flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil } }
    public var castMembers: [Person] {
        let directors = (credits?.crew ?? []).filter { $0.job?.localizedCaseInsensitiveContains("Director") == true }
        return Array((directors + (credits?.cast ?? [])).prefix(18))
    }
    public var related: [Recommendation] { Array((recommendations?.results ?? []).prefix(12)) }
    /// Prefer US theatrical/TV rating, then China, then any published rating.
    private var selectedParentalRating: (country: String, rating: String)? {
        let tvRatings = contentRatings?.results.compactMap { country -> (String, String)? in
            let rating = country.rating.trimmingCharacters(in: .whitespacesAndNewlines)
            return rating.isEmpty ? nil : (country.isoCountry, rating)
        } ?? []
        let movieRatings = releaseDates?.results.compactMap { country -> (String, String)? in
            guard let rating = country.releaseDates
                .map({ $0.certification?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" })
                .first(where: { !$0.isEmpty }) else { return nil }
            return (country.isoCountry, rating)
        } ?? []
        let ratings = tvRatings + movieRatings
        return ratings.first(where: { $0.0 == "US" })
            ?? ratings.first(where: { $0.0 == "CN" })
            ?? ratings.first
    }

    public var parentalRating: String? { selectedParentalRating?.rating }
    public var parentalRatingCountry: String? {
        switch selectedParentalRating?.country {
        case "US": return "美国分级"
        case "CN": return "中国分级"
        case let country?: return "\(country) 分级"
        case nil: return nil
        }
    }

    public var parentalRatingSummary: String? {
        guard let rating = parentalRating?.uppercased() else { return nil }
        switch rating {
        case "G", "TV-G", "TV-Y", "TV-Y7": return "适合儿童或全年龄观看"
        case "PG", "TV-PG", "TV-Y7-FV": return "建议家长陪同指导"
        case "PG-13", "TV-14": return "建议 13/14 岁以上观看，家长酌情指导"
        case "R", "TV-MA": return "含成人向内容，未成年人需家长指导"
        case "NC-17": return "仅适合成人观看"
        default: return "官方分级：\(parentalRating ?? rating)"
        }
    }
    public var trailers: [Video] {
        let candidates = (videos?.results ?? []).filter { $0.youtubeURL != nil }
        return Array(candidates.sorted { lhs, rhs in
            let left = lhs.type.localizedCaseInsensitiveContains("Trailer")
            let right = rhs.type.localizedCaseInsensitiveContains("Trailer")
            if left != right { return left }
            return (lhs.official ?? false) && !(rhs.official ?? false)
        }.prefix(8))
    }
    public var genresText: String { (genres ?? []).map(\.name).joined(separator: " · ") }
}

public struct CatalogMetadataService {
    public init() {}

    private struct SearchResponse: Decodable {
        struct Match: Decodable {
            let id: Int
            let mediaType: String?
            let title: String?
            let name: String?
            let overview: String?
            let posterPath: String?
            let backdropPath: String?
            let voteAverage: Double?
            let releaseDate: String?
            let firstAirDate: String?

            enum CodingKeys: String, CodingKey {
                case id, title, name, overview
                case mediaType = "media_type"
                case posterPath = "poster_path"
                case backdropPath = "backdrop_path"
                case voteAverage = "vote_average"
                case releaseDate = "release_date"
                case firstAirDate = "first_air_date"
            }
        }
        let results: [Match]
    }

    public func fetch(title: String, apiKey: String) async throws -> CatalogMetadata? {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard var search = URLComponents(string: "https://api.themoviedb.org/3/search/multi") else {
            throw URLError(.badURL)
        }
        search.queryItems = [
            URLQueryItem(name: "query", value: title),
            URLQueryItem(name: "language", value: "zh-CN"),
            URLQueryItem(name: "include_adult", value: "false"),
            URLQueryItem(name: "api_key", value: apiKey)
        ]
        guard let searchURL = search.url else { throw URLError(.badURL) }
        var request = URLRequest(url: searchURL, timeoutInterval: 12)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let results = try JSONDecoder().decode(SearchResponse.self, from: data).results
        guard let match = results.first(where: { $0.mediaType == "movie" || $0.mediaType == "tv" }) else { return nil }
        let kind = match.mediaType == "tv" ? "tv" : "movie"
        guard var details = URLComponents(string: "https://api.themoviedb.org/3/\(kind)/\(match.id)") else {
            throw URLError(.badURL)
        }
        details.queryItems = [
            URLQueryItem(name: "language", value: "zh-CN"),
            URLQueryItem(name: "append_to_response", value: "credits,recommendations,videos,release_dates,content_ratings"),
            URLQueryItem(name: "api_key", value: apiKey)
        ]
        guard let detailsURL = details.url else { throw URLError(.badURL) }
        var detailRequest = URLRequest(url: detailsURL, timeoutInterval: 12)
        detailRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        let (detailData, detailResponse) = try await URLSession.shared.data(for: detailRequest)
        guard (detailResponse as? HTTPURLResponse)?.statusCode == 200 else {
            return CatalogMetadata(
                overview: match.overview, backdropPath: match.backdropPath, posterPath: match.posterPath,
                voteAverage: match.voteAverage, releaseDate: match.releaseDate, firstAirDate: match.firstAirDate,
                genres: nil, credits: nil, recommendations: nil, videos: nil,
                releaseDates: nil, contentRatings: nil
            )
        }
        return try JSONDecoder().decode(CatalogMetadata.self, from: detailData)
    }
}

/// Resolves a transparent movie/series wordmark for the player header.
/// TMDB provides these through each movie or TV show's `/images` endpoint.
public actor TMDBTitleLogoResolver {
    public static let shared = TMDBTitleLogoResolver()

    private struct SearchResponse: Decodable {
        struct Result: Decodable {
            let id: Int
            let mediaType: String?
            let title: String?
            let name: String?
            let backdropPath: String?

            enum CodingKeys: String, CodingKey {
                case id, title, name
                case mediaType = "media_type"
                case backdropPath = "backdrop_path"
            }
        }
        let results: [Result]
    }

    private struct ImagesResponse: Decodable {
        struct Logo: Decodable {
            let filePath: String
            let language: String?
            let voteAverage: Double?
            let width: Int?
            let height: Int?

            enum CodingKeys: String, CodingKey {
                case filePath = "file_path"
                case language = "iso_639_1"
                case voteAverage = "vote_average"
                case width, height
            }

            var isWide: Bool {
                guard let width, let height, height > 0 else { return false }
                return Double(width) / Double(height) >= 1.35
            }
        }
        let logos: [Logo]
    }

    private var cachedURLs: [String: URL] = [:]
    private var cachedMisses = Set<String>()
    private var cachedBackdropURLs: [String: URL] = [:]
    private var cachedBackdropMisses = Set<String>()

    public func backdropURL(for title: String, apiKey: String) async -> URL? {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = "\(TMDBEndpoint.apiBase)|\(cleanTitle.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))"
        guard !cleanTitle.isEmpty, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let cached = cachedBackdropURLs[key] { return cached }
        if cachedBackdropMisses.contains(key) { return nil }

        let resolved = await fetchBackdropURL(for: cleanTitle, apiKey: apiKey)
        guard !Task.isCancelled else { return nil }
        if let resolved {
            cachedBackdropURLs[key] = resolved
        } else {
            cachedBackdropMisses.insert(key)
        }
        return resolved
    }

    private func fetchBackdropURL(for title: String, apiKey: String) async -> URL? {
        let apiRoot = TMDBEndpoint.apiBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var search = URLComponents(string: "\(apiRoot)/search/multi") else { return nil }
        search.queryItems = [
            URLQueryItem(name: "query", value: title),
            URLQueryItem(name: "language", value: "zh-CN"),
            URLQueryItem(name: "include_adult", value: "false"),
            URLQueryItem(name: "api_key", value: apiKey)
        ]
        guard let searchURL = search.url,
              let searchData = await responseData(for: searchURL),
              let results = try? JSONDecoder().decode(SearchResponse.self, from: searchData).results,
              let match = results.first(where: {
                  ($0.mediaType == "movie" || $0.mediaType == "tv")
                      && Self.normalizedTitle($0.title ?? $0.name ?? "") == Self.normalizedTitle(title)
              }),
              let backdropPath = match.backdropPath else { return nil }

        let imageRoot = TMDBEndpoint.imageBase
            .replacingOccurrences(of: "/w500", with: "/w1280")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(imageRoot)/\(backdropPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")))")
    }

    public func logoURL(for title: String, apiKey: String) async -> URL? {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = "\(TMDBEndpoint.apiBase)|\(cleanTitle.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))"
        guard !cleanTitle.isEmpty, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let cached = cachedURLs[key] { return cached }
        if cachedMisses.contains(key) { return nil }

        let resolved = await fetchLogoURL(for: cleanTitle, apiKey: apiKey)
        guard !Task.isCancelled else { return nil }
        if let resolved {
            cachedURLs[key] = resolved
        } else {
            cachedMisses.insert(key)
        }
        return resolved
    }

    private func fetchLogoURL(for title: String, apiKey: String) async -> URL? {
        let apiRoot = TMDBEndpoint.apiBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var search = URLComponents(string: "\(apiRoot)/search/multi") else { return nil }
        search.queryItems = [
            URLQueryItem(name: "query", value: title),
            URLQueryItem(name: "language", value: "zh-CN"),
            URLQueryItem(name: "include_adult", value: "false"),
            URLQueryItem(name: "api_key", value: apiKey)
        ]
        guard let searchURL = search.url,
              let searchData = await responseData(for: searchURL),
              let results = try? JSONDecoder().decode(SearchResponse.self, from: searchData).results,
              let match = results.first(where: {
                  guard $0.mediaType == "movie" || $0.mediaType == "tv" else { return false }
                  return Self.normalizedTitle($0.title ?? $0.name ?? "") == Self.normalizedTitle(title)
              }) else { return nil }

        let mediaType = match.mediaType == "tv" ? "tv" : "movie"
        guard var images = URLComponents(string: "\(apiRoot)/\(mediaType)/\(match.id)/images") else { return nil }
        images.queryItems = [
            URLQueryItem(name: "include_image_language", value: "zh,en,null"),
            URLQueryItem(name: "api_key", value: apiKey)
        ]
        guard let imagesURL = images.url,
              let imagesData = await responseData(for: imagesURL),
              let logos = try? JSONDecoder().decode(ImagesResponse.self, from: imagesData).logos,
              !logos.isEmpty else { return nil }

        let selected = logos.sorted { lhs, rhs in
            let lhsLanguage = Self.languageRank(lhs.language)
            let rhsLanguage = Self.languageRank(rhs.language)
            if lhsLanguage != rhsLanguage { return lhsLanguage < rhsLanguage }
            if lhs.isWide != rhs.isWide { return lhs.isWide }
            if lhs.voteAverage != rhs.voteAverage { return (lhs.voteAverage ?? 0) > (rhs.voteAverage ?? 0) }
            return (lhs.width ?? 0) > (rhs.width ?? 0)
        }.first
        guard let filePath = selected?.filePath else { return nil }
        let imageRoot = TMDBEndpoint.imageBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(imageRoot)/\(filePath.trimmingCharacters(in: CharacterSet(charactersIn: "/")))")
    }

    private func responseData(for url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    private static func normalizedTitle(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func languageRank(_ language: String?) -> Int {
        switch language?.lowercased() {
        case "zh": 0
        case "en": 1
        case nil: 2
        default: 3
        }
    }
}
