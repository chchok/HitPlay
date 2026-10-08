import Foundation

/// TMDB 接口与图片地址（设置 → API 设置可覆盖；留空用官方地址）。
public enum TMDBEndpoint {
    public static var apiBase: String {
        let stored = UserDefaults.standard.string(forKey: "hitplay.tmdb.apiBase") ?? ""
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "https://api.themoviedb.org/3" : trimmed
    }
    public static var imageBase: String {
        let stored = UserDefaults.standard.string(forKey: "hitplay.tmdb.imageBase") ?? ""
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "https://image.tmdb.org/t/p/w500" : trimmed
    }
}
