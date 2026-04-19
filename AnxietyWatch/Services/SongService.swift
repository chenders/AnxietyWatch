import Foundation
import SwiftData

/// API client for the server's song endpoints.
/// Uses the same server URL and API key as SyncService.
enum SongService {

    // MARK: - Search

    /// Search result from Genius API (via server proxy).
    struct SearchResult: Decodable, Identifiable {
        let geniusId: Int
        let title: String
        let artist: String
        let albumArtUrl: String?

        var id: Int { geniusId }

        enum CodingKeys: String, CodingKey {
            case geniusId = "genius_id"
            case title, artist
            case albumArtUrl = "album_art_url"
        }
    }

    /// Server song response after adding a song.
    struct ServerSong: Decodable {
        let id: Int
        let geniusId: Int?
        let title: String
        let artist: String
        let album: String?
        let albumArtUrl: String?
        let geniusUrl: String?
        let lyrics: String?
        let lyricsSource: String?

        enum CodingKeys: String, CodingKey {
            case id
            case geniusId = "genius_id"
            case title, artist, album
            case albumArtUrl = "album_art_url"
            case geniusUrl = "genius_url"
            case lyrics
            case lyricsSource = "lyrics_source"
        }
    }

    enum SongError: Error {
        case notConfigured
        case invalidURL
        case serverError(Int)
        case decodingError
    }

    // MARK: - API Calls

    /// Search for songs via server proxy to Genius API.
    static func search(query: String) async throws -> [SearchResult] {
        let sync = SyncService.shared
        guard sync.isConfigured else { throw SongError.notConfigured }

        guard var components = URLComponents(string: sync.serverURL) else {
            throw SongError.invalidURL
        }
        components.path = "/api/songs/search"
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { throw SongError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(sync.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SongError.serverError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        struct Response: Decodable { let results: [SearchResult] }
        return try JSONDecoder().decode(Response.self, from: data).results
    }

    /// Add a song to the server catalog by Genius ID.
    /// Returns the server song with metadata and lyrics.
    static func addByGeniusId(_ geniusId: Int) async throws -> ServerSong {
        let sync = SyncService.shared
        guard sync.isConfigured else { throw SongError.notConfigured }

        guard var components = URLComponents(string: sync.serverURL) else {
            throw SongError.invalidURL
        }
        components.path = "/api/songs"
        guard let url = components.url else { throw SongError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(sync.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["genius_id": geniusId])
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SongError.serverError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        return try JSONDecoder().decode(ServerSong.self, from: data)
    }

    /// Fetch the full song catalog from the server and upsert into SwiftData.
    /// Called after sync to pull songs added/updated via admin UI or server-side scraping.
    /// Returns the number of songs added or updated.
    @discardableResult
    static func fetchCatalog(into context: ModelContext) async throws -> Int {
        let sync = SyncService.shared
        guard sync.isConfigured else { throw SongError.notConfigured }

        guard var components = URLComponents(string: sync.serverURL) else {
            throw SongError.invalidURL
        }
        components.path = "/api/songs"
        guard let url = components.url else { throw SongError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(sync.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SongError.serverError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        struct CatalogSong: Decodable {
            let id: Int
            let geniusId: Int?
            let title: String
            let artist: String
            let album: String?
            let albumArtUrl: String?
            let hasLyrics: Bool

            enum CodingKeys: String, CodingKey {
                case id
                case geniusId = "genius_id"
                case title, artist, album
                case albumArtUrl = "album_art_url"
                case hasLyrics = "has_lyrics"
            }
        }
        struct Response: Decodable { let songs: [CatalogSong] }
        let catalog = try JSONDecoder().decode(Response.self, from: data).songs

        var count = 0
        for entry in catalog {
            // Check if song already exists locally by serverId
            let serverId = entry.id
            let descriptor = FetchDescriptor<Song>(
                predicate: #Predicate<Song> { $0.serverId == serverId }
            )
            if (try? context.fetch(descriptor).first) != nil {
                continue  // Already have this song
            }

            // Also check by geniusId
            if let geniusId = entry.geniusId {
                let geniusDescriptor = FetchDescriptor<Song>(
                    predicate: #Predicate<Song> { $0.geniusId == geniusId }
                )
                if let existing = try? context.fetch(geniusDescriptor).first {
                    existing.serverId = serverId
                    count += 1
                    continue
                }
            }

            // New song — insert
            let song = Song(
                title: entry.title,
                artist: entry.artist,
                album: entry.album,
                geniusId: entry.geniusId,
                albumArtURL: entry.albumArtUrl
            )
            song.serverId = serverId
            context.insert(song)
            count += 1
        }

        if count > 0 {
            try context.save()
        }
        return count
    }

    /// Persist a server song into the local SwiftData catalog.
    /// If a Song with the same geniusId already exists, updates it instead.
    @discardableResult
    static func upsertLocal(from server: ServerSong, in context: ModelContext) throws -> Song {
        if let geniusId = server.geniusId {
            let descriptor = FetchDescriptor<Song>(
                predicate: #Predicate<Song> { $0.geniusId == geniusId }
            )
            if let existing = try context.fetch(descriptor).first {
                existing.serverId = server.id
                existing.title = server.title
                existing.artist = server.artist
                existing.album = server.album
                existing.albumArtURL = server.albumArtUrl
                existing.geniusURL = server.geniusUrl
                if server.lyrics != nil {
                    existing.lyrics = server.lyrics
                    existing.lyricsSource = server.lyricsSource
                }
                existing.updatedAt = Date()
                return existing
            }
        }

        let song = Song(
            title: server.title,
            artist: server.artist,
            album: server.album,
            geniusId: server.geniusId,
            albumArtURL: server.albumArtUrl,
            geniusURL: server.geniusUrl
        )
        song.serverId = server.id
        song.lyrics = server.lyrics
        song.lyricsSource = server.lyricsSource
        context.insert(song)
        return song
    }
}
