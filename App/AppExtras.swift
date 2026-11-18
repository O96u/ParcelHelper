import SwiftUI
import Foundation

private struct GitHubRelease: Decodable { let tag_name: String }
enum GitHubReleaseVersion {
    static func latest() async -> String? {
        guard let url = URL(string: "https://api.github.com/repos/O96u/ParcelHelper/releases/latest") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ParcelHelper", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let tag = try JSONDecoder().decode(GitHubRelease.self, from: data).tag_name
            return tag.isEmpty ? nil : tag
        } catch { return nil }
    }
}
