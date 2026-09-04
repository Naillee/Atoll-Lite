/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Atoll (DynamicIsland)
 * See NOTICE for details.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import AppKit
import Combine
import CoreFoundation
import Defaults
import Foundation
import SwiftUI

// MARK: - Lyric Data Structures
struct LyricToken: Identifiable, Codable {
    let id = UUID()
    let text: String
    let pronunciation: String?
}

struct LyricLine: Identifiable, Codable {
    let id = UUID()
    let timestamp: TimeInterval
    let text: String
    let pronunciationTokens: [LyricToken]?
    let romanization: String?
    let translation: String?

    init(
        timestamp: TimeInterval,
        text: String,
        pronunciationTokens: [LyricToken]? = nil,
        romanization: String? = nil,
        translation: String? = nil
    ) {
        self.timestamp = timestamp
        self.text = text
        self.pronunciationTokens = pronunciationTokens
        self.romanization = romanization
        self.translation = translation
    }
}

private enum LyricsLanguage: Equatable {
    case japanese
    case korean
    case other
}

private enum KoreanRomanizationTables {
    static let initials = [
        "g", "kk", "n", "d", "tt", "r", "m", "b", "pp", "s",
        "ss", "", "j", "jj", "ch", "k", "t", "p", "h"
    ]
    static let vowels = [
        "a", "ae", "ya", "yae", "eo", "e", "yeo", "ye", "o", "wa",
        "wae", "oe", "yo", "u", "wo", "we", "wi", "yu", "eu", "ui", "i"
    ]
    static let finals = [
        "", "k", "k", "k", "n", "n", "n", "t", "l", "k", "m", "p", "l", "l",
        "p", "l", "m", "p", "p", "t", "t", "ng", "t", "t", "k", "t", "p", "t"
    ]
    static let liaisonCodas = [
        "", "", "", "k", "", "n", "n", "", "", "l", "l", "l", "l", "l",
        "l", "l", "", "", "p", "", "", "", "", "", "", "", "", ""
    ]
    static let liaisonOnsets = [
        "", "g", "kk", "s", "n", "j", "", "d", "r", "g", "m", "b", "s", "t",
        "p", "", "m", "b", "s", "s", "ss", "ng", "j", "ch", "k", "t", "p", ""
    ]
}

private struct LyricsLookupKey: Hashable {
    let title: String
    let artist: String
    let album: String

    var isValid: Bool {
        !title.isEmpty && !artist.isEmpty
    }
}

private struct LRCLIBLyricsResult: Decodable {
    let trackName: String
    let artistName: String
    let albumName: String?
    let duration: Double?
    let plainLyrics: String?
    let syncedLyrics: String?
}

private struct NetEaseSearchResponse: Decodable {
    let result: NetEaseSearchResult?
}

private struct NetEaseSearchResult: Decodable {
    let songs: [NetEaseSong]?
}

private struct NetEaseSong: Decodable {
    struct Artist: Decodable { let name: String }
    struct Album: Decodable { let name: String }

    let id: Int
    let name: String
    let artists: [Artist]
    let album: Album
    let duration: Double
}

private struct NetEaseLyricsResponse: Decodable {
    struct Lyrics: Decodable { let lyric: String? }

    let lrc: Lyrics?
    let tlyric: Lyrics?
    let romalrc: Lyrics?
    let nolyric: Bool?
    let uncollected: Bool?
}

let defaultImage: NSImage = .init(
    systemSymbolName: "heart.fill",
    accessibilityDescription: "Album Art"
)!

private struct ITunesExplicitnessSearchResponse: Decodable {
    let results: [ITunesExplicitnessTrack]
}

private struct ITunesExplicitnessTrack: Decodable {
    let trackName: String?
    let artistName: String?
    let collectionName: String?
    let trackExplicitness: String?
}

private actor MusicExplicitnessResolver {
    struct LookupKey: Hashable, Sendable {
        let title: String
        let artist: String
        let album: String

        init(title: String, artist: String, album: String) {
            self.title = MusicExplicitnessResolver.normalize(title)
            self.artist = MusicExplicitnessResolver.normalize(artist)
            self.album = MusicExplicitnessResolver.normalize(album)
        }

        var canResolve: Bool {
            !title.isEmpty && !artist.isEmpty
        }
    }

    static let shared = MusicExplicitnessResolver()

    private let session = URLSession(configuration: .ephemeral)
    private static let cacheLimit = 300
    private var cache: [LookupKey: Bool] = [:]
    private var cacheOrder: [LookupKey] = []
    private var inFlightTasks: [LookupKey: Task<Bool, Never>] = [:]

    private func store(_ value: Bool, for key: LookupKey) {
        if cache[key] == nil {
            cacheOrder.append(key)
            while cacheOrder.count > Self.cacheLimit {
                let evicted = cacheOrder.removeFirst()
                cache.removeValue(forKey: evicted)
            }
        }
        cache[key] = value
    }

    func resolve(title: String, artist: String, album: String) async -> Bool {
        let key = LookupKey(title: title, artist: artist, album: album)
        guard key.canResolve else { return false }

        if let cached = cache[key] {
            return cached
        }

        if let inFlightTask = inFlightTasks[key] {
            return await inFlightTask.value
        }

        let task = Task<Bool, Never> { [session] in
            await Self.fetchExplicitness(for: key, using: session)
        }

        inFlightTasks[key] = task
        let result = await task.value
        store(result, for: key)
        inFlightTasks[key] = nil
        return result
    }

    private static func fetchExplicitness(for key: LookupKey, using session: URLSession) async -> Bool {
        let query = "\(key.title) \(key.artist)"
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(
                string: "https://itunes.apple.com/search?term=\(encoded)&media=music&entity=song&limit=15")
        else {
            return false
        }

        do {
            let (data, _) = try await session.data(from: url)
            let response = try JSONDecoder().decode(ITunesExplicitnessSearchResponse.self, from: data)

            let bestMatch = response.results
                .map { track in (track, matchScore(for: track, key: key)) }
                .max { lhs, rhs in lhs.1 < rhs.1 }

            guard let bestMatch,
                  bestMatch.1 >= 8
            else {
                return false
            }

            return bestMatch.0.trackExplicitness?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == "explicit"
        } catch {
            return false
        }
    }

    private static func matchScore(for track: ITunesExplicitnessTrack, key: LookupKey) -> Int {
        let trackTitle = canonicalTitle(track.trackName ?? "")
        guard !trackTitle.isEmpty else { return Int.min }

        let keyTitle = canonicalTitle(key.title)
        let trackArtist = normalize(track.artistName ?? "")
        let trackAlbum = normalize(track.collectionName ?? "")

        var score = 0

        if trackTitle == keyTitle {
            score += 6
        } else if trackTitle.contains(keyTitle) || keyTitle.contains(trackTitle) {
            score += 4
        } else {
            return Int.min
        }

        if !key.artist.isEmpty {
            if trackArtist == key.artist {
                score += 4
            } else if trackArtist.contains(key.artist) || key.artist.contains(trackArtist) {
                score += 2
            }
        }

        if !key.album.isEmpty {
            if trackAlbum == key.album {
                score += 2
            } else if !trackAlbum.isEmpty && (trackAlbum.contains(key.album) || key.album.contains(trackAlbum)) {
                score += 1
            }
        }

        return score
    }

    private static func canonicalTitle(_ value: String) -> String {
        var title = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        title = title.replacingOccurrences(
            of: #"\([^)]*\)|\[[^\]]*\]"#,
            with: " ",
            options: .regularExpression
        )
        title = title.replacingOccurrences(
            of: #"\s-\s(?:\d{4}\s)?(?:remaster(?:ed)?|live|edit|mix|version|mono|stereo).*$"#,
            with: " ",
            options: .regularExpression
        )
        return normalize(title)
    }

    private static func normalize(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let stripped = folded.replacingOccurrences(
            of: #"[^a-z0-9]+"#,
            with: " ",
            options: .regularExpression
        )
        return stripped
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private actor SpotifyExplicitnessResolver {
    struct LookupKey: Hashable, Sendable {
        let trackID: String

        init?(contentIdentifier: String?, contentURL: String?) {
            guard let trackID = SpotifyExplicitnessResolver.extractTrackID(from: contentIdentifier)
                ?? SpotifyExplicitnessResolver.extractTrackID(from: contentURL)
            else {
                return nil
            }

            self.trackID = trackID
        }
    }

    static let shared = SpotifyExplicitnessResolver()

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0",
            "Accept-Language": "en-US,en;q=0.9"
        ]
        return URLSession(configuration: configuration)
    }()

    private static let cacheLimit = 300
    private var cache: [LookupKey: Bool] = [:]
    private var cacheOrder: [LookupKey] = []
    private var inFlightTasks: [LookupKey: Task<Bool?, Never>] = [:]

    private func store(_ value: Bool, for key: LookupKey) {
        if cache[key] == nil {
            cacheOrder.append(key)
            while cacheOrder.count > Self.cacheLimit {
                let evicted = cacheOrder.removeFirst()
                cache.removeValue(forKey: evicted)
            }
        }
        cache[key] = value
    }

    func resolve(key: LookupKey) async -> Bool? {
        if let cached = cache[key] {
            return cached
        }

        if let inFlightTask = inFlightTasks[key] {
            return await inFlightTask.value
        }

        let task = Task<Bool?, Never> { [session] in
            await Self.fetchExplicitness(for: key, using: session)
        }

        inFlightTasks[key] = task
        let result = await task.value
        if let result {
            store(result, for: key)
        }
        inFlightTasks[key] = nil
        return result
    }

    private static func fetchExplicitness(for key: LookupKey, using session: URLSession) async -> Bool? {
        guard let url = URL(string: "https://open.spotify.com/embed/track/\(key.trackID)") else {
            return nil
        }

        do {
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let html = String(data: data, encoding: .utf8)
            else {
                return nil
            }

            if let isExplicit = parseIsExplicitDirectly(from: html) {
                return isExplicit
            }

            if let nextDataJSON = extractNextDataJSON(from: html),
               let isExplicit = parseIsExplicit(from: nextDataJSON) {
                return isExplicit
            }

            return nil
        } catch {
            return nil
        }
    }

    private static func extractNextDataJSON(from html: String) -> String? {
        let pattern = #"<script[^>]*id="__NEXT_DATA__"[^>]*>(.*?)</script>"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ) else {
            return nil
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              match.numberOfRanges > 1,
              let jsonRange = Range(match.range(at: 1), in: html)
        else {
            return nil
        }

        return String(html[jsonRange])
    }

    private static func parseIsExplicitDirectly(from html: String) -> Bool? {
        if let value = captureFirstMatch(
            in: html,
            pattern: #""isExplicit"\s*:\s*(true|false)"#
        ) {
            return value == "true"
        }

        if let label = captureFirstMatch(
            in: html,
            pattern: #""label"\s*:\s*"([A-Z_]+)""#
        ) {
            switch label {
            case "EXPLICIT":
                return true
            case "NON_EXPLICIT":
                return false
            default:
                break
            }
        }

        return nil
    }

    private static func captureFirstMatch(in source: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = regex.firstMatch(in: source, options: [], range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: source)
        else {
            return nil
        }

        return String(source[valueRange]).lowercased()
    }

    private static func parseIsExplicit(from nextDataJSON: String) -> Bool? {
        guard let data = nextDataJSON.data(using: .utf8),
              let rootObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let props = rootObject["props"] as? [String: Any],
              let pageProps = props["pageProps"] as? [String: Any],
              let state = pageProps["state"] as? [String: Any],
              let dataObject = state["data"] as? [String: Any],
              let entity = dataObject["entity"] as? [String: Any]
        else {
            return nil
        }

        if let isExplicit = entity["isExplicit"] as? Bool {
            return isExplicit
        }

        if let contentRating = entity["contentRating"] as? [String: Any],
           let label = contentRating["label"] as? String {
            return label.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "EXPLICIT"
        }

        return nil
    }

    private static func extractTrackID(from rawValue: String?) -> String? {
        guard let rawValue else { return nil }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("spotify:track:") {
            return validatedTrackID(String(trimmed.split(separator: ":").last ?? ""))
        }

        if let url = URL(string: trimmed) {
            let pathComponents = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
            if let trackIndex = pathComponents.firstIndex(of: "track"),
               trackIndex + 1 < pathComponents.count {
                return validatedTrackID(pathComponents[trackIndex + 1])
            }
        }

        return validatedTrackID(trimmed)
    }

    private static func validatedTrackID<S: StringProtocol>(_ candidate: S) -> String? {
        let value = String(candidate).trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"^[A-Za-z0-9]{22}$"#, options: .regularExpression) != nil else {
            return nil
        }

        return value
    }
}

class MusicManager: ObservableObject {
    enum SkipDirection: Equatable {
        case backward
        case forward
    }

    struct SkipGesturePulse: Equatable {
        let token: Int
        let direction: SkipDirection
        let behavior: MusicSkipBehavior
    }

    static let skipGestureSeekInterval: TimeInterval = 10

    // MARK: - Properties
    static let shared = MusicManager()
    private var cancellables = Set<AnyCancellable>()
    private var controllerCancellables = Set<AnyCancellable>()
    private var debounceIdleTask: Task<Void, Never>?
    @MainActor private var pendingOptimisticPlayState: Bool?

    // Helper to check if macOS has removed support for NowPlayingController
    public private(set) var isNowPlayingDeprecated: Bool = false
    private let mediaChecker = MediaChecker()

    // Active controller
    private var activeController: (any MediaControllerProtocol)?

    // Pear Desktop auto-detection
    private static let pearDesktopBundleID = YouTubeMusicConfiguration.default.bundleIdentifier
    private var isPearDesktopAutoSwitched: Bool = false

    // Published properties for UI
    @Published var songTitle: String = "I'm Handsome"
    @Published var artistName: String = "Me"
    @Published var albumArt: NSImage = defaultImage
    @Published var isPlaying = false
    @Published var album: String = "Self Love"
    @Published var isPlayerIdle: Bool = true
    @Published var isCurrentTrackExplicit: Bool = false

    /// Whether there is an active music session with real metadata.
    /// Returns `false` only when the metadata is still placeholder/fallback defaults
    /// (i.e. nothing has been played since app launch, or the controller returned
    /// unknown/not-playing placeholders). Paused music with real metadata is still
    /// considered an active session.
    private static let placeholderTitles: Set<String> = [
        "i'm handsome", "unknown", "not playing"
    ]
    private static let placeholderArtists: Set<String> = [
        "me", "unknown"
    ]

    var hasActiveSession: Bool {
        if isPlaying { return true }
        let trimmedTitle = songTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmedArtist = artistName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasRealTitle = !trimmedTitle.isEmpty && !Self.placeholderTitles.contains(trimmedTitle)
        let hasRealArtist = !trimmedArtist.isEmpty && !Self.placeholderArtists.contains(trimmedArtist)
        return hasRealTitle || hasRealArtist
    }

    @Published var animations: DynamicIslandAnimations = .init()
    @Published var avgColor: NSColor = .white
    @Published var bundleIdentifier: String? = nil
    @Published var songDuration: TimeInterval = 0
    @Published var elapsedTime: TimeInterval = 0
    @Published var timestampDate: Date = .init()
    @Published var playbackRate: Double = 1
    @Published var isShuffled: Bool = false
    @Published var repeatMode: RepeatMode = .off
    @Published var isLiveStream: Bool = false
    @ObservedObject var coordinator = DynamicIslandViewCoordinator.shared
    @Published var usingAppIconForArtwork: Bool = false
    @Published private(set) var skipGesturePulse: SkipGesturePulse?

    // MARK: - Lyrics Properties
    @Published var currentLyrics: String = ""
    @Published var syncedLyrics: [LyricLine] = []
    @Published var showLyrics: Bool = false
    @Published var currentLyricIndex: Int = -1

    // Task used to periodically sync displayed lyric with playback position
    private var lyricSyncTask: Task<Void, Never>?
    private var lyricsFetchTask: Task<Void, Never>?
    private var lyricsFetchKey: LyricsLookupKey?
    private var activeLyricsKey: LyricsLookupKey?
    private var lyricsCache: [LyricsLookupKey: [LyricLine]] = [:]
    // Bounded, insertion-order eviction so the cache cannot grow unboundedly.
    private static let lyricsCacheLimit = 80
    private static let lyricDisplayLeadTime: TimeInterval = 0.18
    private static let lyricSyncIntervalNanoseconds: UInt64 = 100_000_000
    private var lyricsCacheOrder: [LyricsLookupKey] = []
    private var explicitLookupTask: Task<Void, Never>?
    private var explicitLookupKey: String?

    /// Inserts lyrics with insertion-order eviction to keep the cache bounded.
    private func storeLyricsInCache(_ lyrics: [LyricLine], for key: LyricsLookupKey) {
        if lyricsCache[key] == nil {
            lyricsCacheOrder.append(key)
            while lyricsCacheOrder.count > Self.lyricsCacheLimit {
                let evicted = lyricsCacheOrder.removeFirst()
                lyricsCache.removeValue(forKey: evicted)
            }
        }
        lyricsCache[key] = lyrics
    }

    private(set) var artworkData: Data? = nil

    @Published var videoArtworkURL: URL? = nil

    private var liveStreamUnknownDurationCount: Int = 0
    private var liveStreamEdgeObservationCount: Int = 0
    private var liveStreamCompletionObservationCount: Int = 0
    private var liveStreamCompletionReleaseCount: Int = 0

    // Store last values at the time artwork was changed
    private var lastArtworkTitle: String = "I'm Handsome"
    private var lastArtworkArtist: String = "Me"
    private var lastArtworkAlbum: String = "Self Love"
    private var lastArtworkBundleIdentifier: String? = nil
    private var lastArtworkContentIdentifier: String? = nil
    private var lastArtworkContentURL: String? = nil

    @Published var flipAngle: Double = 0
    @Published var lastFlipDirection: SkipDirection = .forward
    private let flipAnimationDuration: TimeInterval = 0.45
    private var flipCooldownActive: Bool = false

    @Published var isTransitioning: Bool = false
    private var transitionWorkItem: DispatchWorkItem?
    private var skipGestureToken: Int = 0

    // MARK: - Initialization
    init() {
        // Listen for changes to the default controller preference
        NotificationCenter.default.publisher(for: Notification.Name.mediaControllerChanged)
            .sink { [weak self] _ in
                self?.isPearDesktopAutoSwitched = false
                self?.setActiveControllerBasedOnPreference()
            }
            .store(in: &cancellables)

        Defaults.publisher(.enableLyrics)
            .receive(on: RunLoop.main)
            .sink { [weak self] change in
                self?.handleLyricsPreferenceChange(isEnabled: change.newValue)
            }
            .store(in: &cancellables)

        // Observe Pear Desktop launch/terminate for auto-detection
        setupPearDesktopAutoDetection()

        // Initialize deprecation check asynchronously
        Task { @MainActor in
            do {
                self.isNowPlayingDeprecated = try await self.mediaChecker.checkDeprecationStatus()
                print("Deprecation check completed: \(self.isNowPlayingDeprecated)")
            } catch {
                print("Failed to check deprecation status: \(error). Defaulting to false.")
                self.isNowPlayingDeprecated = false
            }
            
            // Check if Pear Desktop is already running at startup
            let pearDesktopRunning = NSWorkspace.shared.runningApplications.contains {
                $0.bundleIdentifier == Self.pearDesktopBundleID
            }
            
            if pearDesktopRunning {
                print("[MusicManager] Pear Desktop detected at startup, auto-switching to YouTubeMusicController")
                self.isPearDesktopAutoSwitched = true
                if let controller = self.createController(for: .youtubeMusic) {
                    self.setActiveController(controller)
                }
            } else {
                // Initialize the active controller after deprecation check
                self.setActiveControllerBasedOnPreference()
            }
        }
    }

    // MARK: - Pear Desktop Auto-Detection
    private func setupPearDesktopAutoDetection() {
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .sink { [weak self] notification in
                guard let self = self,
                      let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == Self.pearDesktopBundleID else { return }

                print("[MusicManager] Pear Desktop launched, auto-switching to YouTubeMusicController")
                self.isPearDesktopAutoSwitched = true
                if let controller = self.createController(for: .youtubeMusic) {
                    self.setActiveController(controller)
                }
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .sink { [weak self] notification in
                guard let self = self,
                      let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == Self.pearDesktopBundleID else { return }

                print("[MusicManager] Pear Desktop terminated, reverting to preferred controller")
                if self.isPearDesktopAutoSwitched {
                    self.isPearDesktopAutoSwitched = false
                    self.setActiveControllerBasedOnPreference()
                }
            }
            .store(in: &cancellables)
    }

    deinit {
        destroy()
    }
    
    public func destroy() {
        debounceIdleTask?.cancel()
        lyricsFetchTask?.cancel()
        lyricSyncTask?.cancel()
        explicitLookupTask?.cancel()
        cancellables.removeAll()
        controllerCancellables.removeAll()
        transitionWorkItem?.cancel()

        // Release active controller
        activeController = nil
    }

    // MARK: - Setup Methods
    private func createController(for type: MediaControllerType) -> (any MediaControllerProtocol)? {
        // Cleanup previous controller
        if activeController != nil {
            controllerCancellables.removeAll()
            activeController = nil
        }

        let newController: (any MediaControllerProtocol)?

        switch type {
        case .nowPlaying:
            // Only create NowPlayingController if not deprecated on this macOS version
            if !self.isNowPlayingDeprecated {
                newController = NowPlayingController()
            } else {
                return nil
            }
        case .appleMusic:
            newController = AppleMusicController()
        case .spotify:
            newController = SpotifyController()
        case .youtubeMusic:
            newController = YouTubeMusicController()
        case .amazonMusic:
            newController = AmazonMusicController()
        }

        // Set up state observation for the new controller
        if let controller = newController {
            controller.playbackStatePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    guard let self = self,
                          self.activeController === controller else { return }
                    self.updateFromPlaybackState(state)
                }
                .store(in: &controllerCancellables)
        }

        return newController
    }

    private func setActiveControllerBasedOnPreference() {
        let preferredType = Defaults[.mediaController]
        print("Preferred Media Controller: \(preferredType)")

        // If NowPlaying is deprecated but that's the preference, use Apple Music instead
        let controllerType = (self.isNowPlayingDeprecated && preferredType == .nowPlaying)
            ? .appleMusic
            : preferredType

        if let controller = createController(for: controllerType) {
            setActiveController(controller)
        } else if controllerType != .appleMusic, let fallbackController = createController(for: .appleMusic) {
            // Fallback to Apple Music if preferred controller couldn't be created
            setActiveController(fallbackController)
        }
    }

    private func setActiveController(_ controller: any MediaControllerProtocol) {
        // Set new active controller
        activeController = controller

        // Get current state from active controller
        forceUpdate()
    }

    @MainActor
    private func applyPlayState(_ state: Bool, animation: Animation?) {
        if let animation {
            var transaction = Transaction()
            transaction.animation = animation
            withTransaction(transaction) {
                self.isPlaying = state
            }
        } else {
            self.isPlaying = state
        }

        self.updateIdleState(state: state)
    }

    // MARK: - Update Methods
    @MainActor
    private func updateFromPlaybackState(_ state: PlaybackState) {
        // Check for playback state changes (playing/paused)
        let eventIsPlaying = state.isPlaying
        let expectedState = pendingOptimisticPlayState
        pendingOptimisticPlayState = nil

        if eventIsPlaying != self.isPlaying {
            let animation: Animation? = (expectedState == eventIsPlaying) ? .smooth(duration: 0.18) : .smooth
            applyPlayState(eventIsPlaying, animation: animation)

            if eventIsPlaying && !state.title.isEmpty && !state.artist.isEmpty {
                self.updateSneakPeek()
            }
        } else {
            self.updateIdleState(state: eventIsPlaying)
        }

        // Check for changes in track metadata using last artwork change values
        let titleChanged = state.title != self.lastArtworkTitle
        let artistChanged = state.artist != self.lastArtworkArtist
        let albumChanged = state.album != self.lastArtworkAlbum
        let bundleChanged = state.bundleIdentifier != self.lastArtworkBundleIdentifier
        let contentIdentifierChanged = state.contentIdentifier != self.lastArtworkContentIdentifier
        let contentURLChanged = state.contentURL != self.lastArtworkContentURL

        // Check for artwork changes
        let artworkChanged = state.artwork != nil && state.artwork != self.artworkData

        let hasContentChange =
            titleChanged
            || artistChanged
            || albumChanged
            || artworkChanged
            || bundleChanged
            || contentIdentifierChanged
            || contentURLChanged
        let liveArtworkChanged = state.liveArtworkURL != self.videoArtworkURL

        if liveArtworkChanged {
            self.videoArtworkURL = state.liveArtworkURL
        }

        // Handle artwork and visual transitions for changed content
        let shouldAutoPeekOnTrackChange = Defaults[.showSneakPeekOnTrackChange]

        if hasContentChange {
            self.triggerFlipAnimation()

            if artworkChanged, let artwork = state.artwork {
                self.updateArtwork(artwork)
            } else if state.artwork == nil {
                // Try to use app icon if no artwork but track changed
                if let appIconImage = AppIconAsNSImage(for: state.bundleIdentifier) {
                    self.usingAppIconForArtwork = true
                    self.updateAlbumArt(newAlbumArt: appIconImage)
                }
            }
            self.artworkData = state.artwork

            // Update last artwork change values
            self.lastArtworkTitle = state.title
            self.lastArtworkArtist = state.artist
            self.lastArtworkAlbum = state.album
            self.lastArtworkBundleIdentifier = state.bundleIdentifier
            self.lastArtworkContentIdentifier = state.contentIdentifier
            self.lastArtworkContentURL = state.contentURL

            if let liveArtworkURL = state.liveArtworkURL {
                self.videoArtworkURL = liveArtworkURL
            } else {
                self.fetchVideoArtwork()
            }

            self.refreshExplicitFlag(for: state)


            // Only update sneak peek if there's actual content and something changed
            if shouldAutoPeekOnTrackChange && !state.title.isEmpty && !state.artist.isEmpty && state.isPlaying {
                self.updateSneakPeek()
            }
        } else if state.isExplicit != nil {
            self.refreshExplicitFlag(for: state)
        }

        let timeChanged = state.currentTime != self.elapsedTime
        let durationChanged = state.duration != self.songDuration
        let playbackRateChanged = state.playbackRate != self.playbackRate
        let shuffleChanged = state.isShuffled != self.isShuffled
        let repeatModeChanged = state.repeatMode != self.repeatMode

        if state.title != self.songTitle {
            self.songTitle = state.title
        }

        if state.artist != self.artistName {
            self.artistName = state.artist
        }

        if state.album != self.album {
            self.album = state.album
        }

        if timeChanged {
            self.elapsedTime = state.currentTime
            // Update current lyric based on elapsed time
            self.updateCurrentLyric(for: state.currentTime)
        }

        if durationChanged {
            self.songDuration = state.duration
        }

        if playbackRateChanged {
            self.playbackRate = state.playbackRate
        }
        
        if shuffleChanged {
            self.isShuffled = state.isShuffled
        }

        if state.bundleIdentifier != self.bundleIdentifier {
            self.bundleIdentifier = state.bundleIdentifier
        }

        if repeatModeChanged {
            self.repeatMode = state.repeatMode
        }
        
        updateLiveStreamState(with: state)
        self.timestampDate = state.lastUpdated

        // Lyrics must be looked up only after the new track metadata and duration
        // have replaced the previous track's values.
        if hasContentChange {
            self.prepareLyricsForCurrentTrack()
        }

        // Manage lyric sync task based on playback/lyrics availability
        if Defaults[.enableLyrics] && !self.syncedLyrics.isEmpty && self.isPlaying {
            // Keep the high-frequency sync loop active only during playback.
            startLyricSync()
        } else {
            stopLyricSync()
        }
    }

    @MainActor
    private func refreshExplicitFlag(for state: PlaybackState) {
        if let explicitValue = state.isExplicit {
            explicitLookupTask?.cancel()
            explicitLookupTask = nil
            explicitLookupKey = nil

            if isCurrentTrackExplicit != explicitValue {
                isCurrentTrackExplicit = explicitValue
            }
            return
        }

        if state.bundleIdentifier == SpotifyController.bundleIdentifier,
           let spotifyLookupKey = SpotifyExplicitnessResolver.LookupKey(
               contentIdentifier: state.contentIdentifier,
               contentURL: state.contentURL
           ) {
            let lookupIdentifier = "spotify|\(spotifyLookupKey.trackID)"
            let fallbackTitle = state.title
            let fallbackArtist = state.artist
            let fallbackAlbum = state.album
            guard explicitLookupKey != lookupIdentifier else { return }

            explicitLookupTask?.cancel()
            explicitLookupKey = lookupIdentifier

            if isCurrentTrackExplicit {
                isCurrentTrackExplicit = false
            }

            explicitLookupTask = Task { [weak self] in
                let isExplicit = await SpotifyExplicitnessResolver.shared.resolve(key: spotifyLookupKey)

                guard !Task.isCancelled else { return }

                await MainActor.run {
                    guard let self,
                          self.explicitLookupKey == lookupIdentifier
                    else {
                        return
                    }

                    self.explicitLookupTask = nil

                    if let isExplicit {
                        self.isCurrentTrackExplicit = isExplicit
                    } else {
                        self.explicitLookupKey = nil
                        self.refreshGenericExplicitFlag(
                            title: fallbackTitle,
                            artist: fallbackArtist,
                            album: fallbackAlbum
                        )
                    }
                }
            }
            return
        }

        refreshGenericExplicitFlag(title: state.title, artist: state.artist, album: state.album)
    }

    @MainActor
    private func refreshGenericExplicitFlag(title: String, artist: String, album: String) {
        let lookupKey = MusicExplicitnessResolver.LookupKey(
            title: title,
            artist: artist,
            album: album
        )
        let lookupIdentifier = "generic|\(lookupKey.title)|\(lookupKey.artist)|\(lookupKey.album)"

        guard lookupKey.canResolve,
              !Self.placeholderTitles.contains(lookupKey.title),
              !Self.placeholderArtists.contains(lookupKey.artist)
        else {
            explicitLookupTask?.cancel()
            explicitLookupTask = nil
            explicitLookupKey = nil
            if isCurrentTrackExplicit {
                isCurrentTrackExplicit = false
            }
            return
        }

        guard explicitLookupKey != lookupIdentifier else { return }

        explicitLookupTask?.cancel()
        explicitLookupKey = lookupIdentifier

        if isCurrentTrackExplicit {
            isCurrentTrackExplicit = false
        }

        explicitLookupTask = Task { [weak self] in
            let isExplicit = await MusicExplicitnessResolver.shared.resolve(
                title: title,
                artist: artist,
                album: album
            )

            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self,
                      self.explicitLookupKey == lookupIdentifier
                else {
                    return
                }

                self.isCurrentTrackExplicit = isExplicit
                self.explicitLookupTask = nil
            }
        }
    }

    private func triggerFlipAnimation() {
        // Debounce: rapid metadata updates (title, artwork, bundle arriving
        // separately for one track change) should only produce a single flip.
        guard !flipCooldownActive else { return }
        flipCooldownActive = true

        // Direction: positive rotation = next (page turn forward),
        //            negative rotation = previous (page turn backward).
        let delta: Double = lastFlipDirection == .forward ? 180 : -180
        withAnimation(.easeInOut(duration: flipAnimationDuration)) {
            flipAngle += delta
        }

        // Reset cooldown after the animation completes so the next
        // genuine track change can flip again.
        DispatchQueue.main.asyncAfter(deadline: .now() + flipAnimationDuration + 0.15) { [weak self] in
            self?.flipCooldownActive = false
        }
    }

    private func updateLiveStreamState(with state: PlaybackState) {
        let duration = state.duration
        let current = max(state.currentTime, elapsedTime)
        let hasKnownDuration = duration.isFinite && duration > 0
        let isPlaying = state.isPlaying

        if hasKnownDuration {
            liveStreamUnknownDurationCount = 0

            let remaining = duration - current
            let clampedDuration = max(duration, 0)
            let clampedCurrent = clampedDuration > 0
                ? max(0, min(current, clampedDuration))
                : max(0, current)
            let progress = clampedDuration > 0 ? clampedCurrent / clampedDuration : 0
            let sliderAppearsComplete = isPlaying && clampedDuration > 0 && progress >= 0.999
            let nearDurationEdge = isPlaying && remaining.isFinite && remaining <= 1.0 && clampedCurrent >= 10

            if sliderAppearsComplete {
                liveStreamCompletionObservationCount = min(liveStreamCompletionObservationCount + 1, 8)
                liveStreamCompletionReleaseCount = 0
            } else {
                liveStreamCompletionReleaseCount = min(liveStreamCompletionReleaseCount + 1, 8)
                if liveStreamCompletionObservationCount > 0 {
                    liveStreamCompletionObservationCount = max(liveStreamCompletionObservationCount - 1, 0)
                }
            }

            if nearDurationEdge || sliderAppearsComplete {
                liveStreamEdgeObservationCount = min(liveStreamEdgeObservationCount + 1, 12)
            } else if liveStreamEdgeObservationCount > 0 {
                liveStreamEdgeObservationCount = max(liveStreamEdgeObservationCount - 1, 0)
            }

            if !isLiveStream {
                if liveStreamCompletionObservationCount >= 3 || liveStreamEdgeObservationCount >= 5 {
                    isLiveStream = true
                }
            } else {
                let shouldClearForKnownDuration =
                    (duration > 10 && remaining > 5)
                    || (liveStreamCompletionObservationCount == 0
                        && liveStreamEdgeObservationCount == 0
                        && liveStreamCompletionReleaseCount >= 4)

                if shouldClearForKnownDuration {
                    isLiveStream = false
                }
            }
        } else if isPlaying {
            liveStreamEdgeObservationCount = max(liveStreamEdgeObservationCount - 1, 0)
            liveStreamCompletionObservationCount = max(liveStreamCompletionObservationCount - 1, 0)
            liveStreamCompletionReleaseCount = 0

            liveStreamUnknownDurationCount = min(liveStreamUnknownDurationCount + 1, 8)
            if liveStreamUnknownDurationCount >= 3 && !isLiveStream {
                isLiveStream = true
            }
        } else {
            liveStreamUnknownDurationCount = 0
            liveStreamEdgeObservationCount = 0
            liveStreamCompletionObservationCount = 0
            liveStreamCompletionReleaseCount = 0
        }
    }

    private func updateArtwork(_ artworkData: Data) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            if let artworkImage = NSImage(data: artworkData) {
                DispatchQueue.main.async { [weak self] in
                    self?.usingAppIconForArtwork = false
                    self?.updateAlbumArt(newAlbumArt: artworkImage)
                }
            }
        }
    }

    private func updateIdleState(state: Bool) {
        if state {
            isPlayerIdle = false
            debounceIdleTask?.cancel()
        } else {
            debounceIdleTask?.cancel()
            debounceIdleTask = Task { [weak self] in
                guard let self = self else { return }
                try? await Task.sleep(for: .seconds(Defaults[.waitInterval]))
                withAnimation {
                    self.isPlayerIdle = !self.isPlaying
                }
            }
        }
    }

    private var workItem: DispatchWorkItem?

    func updateAlbumArt(newAlbumArt: NSImage) {
        workItem?.cancel()
        workItem = DispatchWorkItem { [weak self] in
            withAnimation(.smooth) {
                self?.albumArt = newAlbumArt
                if Defaults[.coloredSpectrogram] {
                    self?.calculateAverageColor()
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: workItem!)
    }

    // MARK: - Playback Position Estimation
    public func estimatedPlaybackPosition(at date: Date = Date()) -> TimeInterval {
        guard isPlaying else { return min(elapsedTime, songDuration) }

        let timeDifference = date.timeIntervalSince(timestampDate)
        let estimated = elapsedTime + (timeDifference * playbackRate)
        return min(max(0, estimated), songDuration)
    }

    func calculateAverageColor() {
        albumArt.averageColor { [weak self] color in
            DispatchQueue.main.async {
                withAnimation(.smooth) {
                    self?.avgColor = color ?? .white
                }
            }
        }
    }

    private func updateSneakPeek() {
        let standardControlsEnabled = Defaults[.showStandardMediaControls]
        let minimalisticEnabled = Defaults[.enableMinimalisticUI]

        guard standardControlsEnabled || minimalisticEnabled else { return }

        if isPlaying && Defaults[.enableSneakPeek] {
            if Defaults[.sneakPeekStyles] == .standard {
                coordinator.toggleSneakPeek(status: true, type: .music)
            } else {
                coordinator.toggleExpandingView(status: true, type: .music)
            }
        }
    }

    // MARK: - Public Methods for controlling playback
    func playPause() {
        Task {
            await activeController?.togglePlay()
        }
    }

    func play() {
        Task {
            await activeController?.play()
        }
    }

    func pause() {
        Task {
            await activeController?.pause()
        }
    }

    func toggleShuffle() {
        Task {
            await activeController?.toggleShuffle()
        }
    }

    func toggleRepeat() {
        Task {
            await activeController?.toggleRepeat()
        }
    }
    
    func togglePlay() {
        guard let controller = activeController else { return }
        let targetState = !isPlaying

        Task {
            await MainActor.run {
                pendingOptimisticPlayState = targetState
                applyPlayState(targetState, animation: .smooth(duration: 0.18))
            }

            if targetState {
                await controller.play()
            } else {
                await controller.pause()
            }
        }
    }

    func nextTrack() {
        Task {
            await activeController?.nextTrack()
        }
    }

    func previousTrack() {
        Task {
            await activeController?.previousTrack()
        }
    }

    func seek(to position: TimeInterval) {
        Task {
            await activeController?.seek(to: position)
        }
    }

    func seek(by offset: TimeInterval) {
        guard !isLiveStream else { return }
        let duration = songDuration
        guard duration > 0 else { return }

        let current = estimatedPlaybackPosition()
        let magnitude = abs(offset)

        if offset < 0, current <= magnitude {
            previousTrack()
            return
        }

        if offset > 0, (duration - current) <= magnitude {
            nextTrack()
            return
        }

        let target = min(max(0, current + offset), duration)
        seek(to: target)
    }

    @MainActor
    func handleSkipGesture(direction: SkipDirection) {
        guard Defaults[.enableHorizontalMusicGestures] else { return }
        guard !isPlayerIdle || bundleIdentifier != nil else { return }

        let behavior = Defaults[.musicGestureBehavior]

        switch behavior {
        case .track:
            if direction == .forward {
                lastFlipDirection = .forward
                nextTrack()
            } else {
                lastFlipDirection = .backward
                previousTrack()
            }
        case .tenSecond:
            let interval = Self.skipGestureSeekInterval
            let offset = direction == .forward ? interval : -interval
            seek(by: offset)
        }

        skipGestureToken = skipGestureToken &+ 1
        skipGesturePulse = SkipGesturePulse(
            token: skipGestureToken,
            direction: direction,
            behavior: behavior
        )
    }

    func openMusicApp() {
        guard let bundleID = bundleIdentifier else {
            print("Error: appBundleIdentifier is nil")
            return
        }

        let workspace = NSWorkspace.shared
        if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) {
            let configuration = NSWorkspace.OpenConfiguration()
            workspace.openApplication(at: appURL, configuration: configuration) { (app, error) in
                if let error = error {
                    print("Failed to launch app with bundle ID: \(bundleID), error: \(error)")
                } else {
                    print("Launched app with bundle ID: \(bundleID)")
                }
            }
        } else {
            print("Failed to find app with bundle ID: \(bundleID)")
        }
    }

    func forceUpdate() {
        // Request immediate update from the active controller
        Task { [weak self] in
            if self?.activeController?.isActive() == true {
                if let youtubeController = self?.activeController as? YouTubeMusicController {
                    await youtubeController.pollPlaybackState()
                } else {
                    await self?.activeController?.updatePlaybackInfo()
                }
            }
        }
    }

    // MARK: - Lyrics Methods
    func fetchLyrics() {
        prepareLyricsForCurrentTrack(forceFetch: true, prioritizeVisibleResult: Defaults[.enableLyrics])
    }

    private func handleLyricsPreferenceChange(isEnabled: Bool) {
        showLyrics = isEnabled

        if isEnabled {
            prepareLyricsForCurrentTrack(prioritizeVisibleResult: true)
        } else {
            stopLyricSync()
        }
    }

    private func prepareLyricsForCurrentTrack(forceFetch: Bool = false, prioritizeVisibleResult: Bool = false) {
        guard let lookup = currentLyricsLookupContext() else {
            activeLyricsKey = nil
            lyricsFetchKey = nil
            lyricsFetchTask?.cancel()
            lyricsFetchTask = nil
            syncedLyrics = []
            currentLyrics = ""
            currentLyricIndex = -1
            stopLyricSync()
            return
        }

        let key = lookup.key
        let lyricsEnabled = Defaults[.enableLyrics]
        let shouldShowLoading = lyricsEnabled && prioritizeVisibleResult
        let trackChanged = activeLyricsKey != key
        activeLyricsKey = key

        if trackChanged {
            syncedLyrics = []
            currentLyricIndex = -1
            currentLyrics = shouldShowLoading ? "正在加载歌词..." : ""
            stopLyricSync()
        }

        if !forceFetch, let cachedLyrics = lyricsCache[key] {
            applyLyricsToDisplay(cachedLyrics)
            return
        }

        if lyricsFetchKey == key {
            if shouldShowLoading && syncedLyrics.isEmpty {
                currentLyrics = "正在加载歌词..."
            }
            return
        }

        lyricsFetchTask?.cancel()
        lyricsFetchKey = key

        if shouldShowLoading || (lyricsEnabled && syncedLyrics.isEmpty) {
            currentLyrics = "正在加载歌词..."
        }

        let requestArtist = lookup.requestArtist
        let requestTitle = lookup.requestTitle
        let requestAlbum = lookup.requestAlbum

        lyricsFetchTask = Task { [weak self] in
            guard let self else { return }

            do {
                let lyrics = try await self.fetchLyricsFromAPI(
                    artist: requestArtist,
                    title: requestTitle,
                    album: requestAlbum,
                    duration: self.songDuration
                )
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    guard self.activeLyricsKey == key else { return }
                    self.storeLyricsInCache(lyrics, for: key)
                    self.lyricsFetchKey = nil
                    self.lyricsFetchTask = nil
                    self.applyLyricsToDisplay(lyrics)
                }
            } catch {
                print("Failed to fetch lyrics: \(error)")
                await MainActor.run {
                    guard self.activeLyricsKey == key else { return }
                    self.lyricsFetchKey = nil
                    self.lyricsFetchTask = nil
                    self.syncedLyrics = []
                    self.currentLyricIndex = -1
                    self.currentLyrics = lyricsEnabled ? "未找到歌词" : ""
                    self.stopLyricSync()
                }
            }
        }
    }

    private func fetchLyricsFromAPI(
        artist: String,
        title: String,
        album: String,
        duration: TimeInterval
    ) async throws -> [LyricLine] {
        guard !artist.isEmpty, !title.isEmpty else { return [] }

        async let lrclibRequest = fetchLyricsFromLRCLIB(
            artist: artist,
            title: title,
            album: album,
            duration: duration
        )
        async let netEaseRequest = fetchLyricsFromNetEase(
            artist: artist,
            title: title,
            album: album,
            duration: duration
        )

        let lrclibLyrics = (try? await lrclibRequest) ?? []
        let netEaseLyrics = (try? await netEaseRequest) ?? []
        let netEaseHasSupplementalLyrics = netEaseLyrics.contains {
            $0.romanization != nil || $0.translation != nil
        }
        let selectedLyrics: [LyricLine]
        if netEaseHasSupplementalLyrics {
            selectedLyrics = netEaseLyrics
        } else {
            let hasSynchronizedLRCLIBLyrics = lrclibLyrics.count > 1
                || lrclibLyrics.contains(where: { $0.timestamp > 0 })
            if hasSynchronizedLRCLIBLyrics {
                selectedLyrics = lrclibLyrics
            } else {
                selectedLyrics = netEaseLyrics.isEmpty ? lrclibLyrics : netEaseLyrics
            }
        }

        return addingPronunciationTokens(to: selectedLyrics)
    }

    private func fetchLyricsFromLRCLIB(
        artist: String,
        title: String,
        album: String,
        duration: TimeInterval
    ) async throws -> [LyricLine] {

        // Normalize input before building a structured query.
        let cleanArtist = artist.folding(options: .diacriticInsensitive, locale: .current)
        let cleanTitle = title.folding(options: .diacriticInsensitive, locale: .current)
        let cleanAlbum = album.folding(options: .diacriticInsensitive, locale: .current)

        // Use LRCLIB search endpoint which returns an array JSON with `plainLyrics` and/or `syncedLyrics`.
        var components = URLComponents(string: "https://lrclib.net/api/search")
        components?.queryItems = [
            URLQueryItem(name: "track_name", value: cleanTitle),
            URLQueryItem(name: "artist_name", value: cleanArtist)
        ]
        guard let url = components?.url else { return [] }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }

        let results = try JSONDecoder().decode([LRCLIBLyricsResult].self, from: data)
        guard let bestMatch = bestLyricsMatch(
            in: results,
            artist: cleanArtist,
            title: cleanTitle,
            album: cleanAlbum,
            duration: duration
        ) else { return [] }

        let plain = bestMatch.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let synced = bestMatch.syncedLyrics?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !synced.isEmpty {
            return parseLRC(synced)
        }
        if !plain.isEmpty {
            return [LyricLine(timestamp: 0, text: simplifiedChinese(plain))]
        }
        return []
    }

    private func fetchLyricsFromNetEase(
        artist: String,
        title: String,
        album: String,
        duration: TimeInterval
    ) async throws -> [LyricLine] {
        var searchComponents = URLComponents(string: "https://music.163.com/api/search/get/web")
        searchComponents?.queryItems = [
            URLQueryItem(name: "s", value: "\(title) \(artist)"),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "total", value: "true"),
            URLQueryItem(name: "limit", value: "20")
        ]
        guard let searchURL = searchComponents?.url else { return [] }

        var searchRequest = URLRequest(url: searchURL)
        searchRequest.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        searchRequest.setValue("Atoll-Lite/1.0", forHTTPHeaderField: "User-Agent")

        let (searchData, searchResponse) = try await URLSession.shared.data(for: searchRequest)
        guard let http = searchResponse as? HTTPURLResponse, http.statusCode == 200 else { return [] }

        let response = try JSONDecoder().decode(NetEaseSearchResponse.self, from: searchData)
        guard let match = bestNetEaseLyricsMatch(
            in: response.result?.songs ?? [],
            artist: artist,
            title: title,
            album: album,
            duration: duration
        ) else { return [] }

        var lyricsComponents = URLComponents(string: "https://music.163.com/api/song/lyric")
        lyricsComponents?.queryItems = [
            URLQueryItem(name: "id", value: String(match.id)),
            URLQueryItem(name: "lv", value: "1"),
            URLQueryItem(name: "kv", value: "1"),
            URLQueryItem(name: "tv", value: "-1")
        ]
        guard let lyricsURL = lyricsComponents?.url else { return [] }

        var lyricsRequest = URLRequest(url: lyricsURL)
        lyricsRequest.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        lyricsRequest.setValue("Atoll-Lite/1.0", forHTTPHeaderField: "User-Agent")

        let (lyricsData, lyricsResponse) = try await URLSession.shared.data(for: lyricsRequest)
        guard let http = lyricsResponse as? HTTPURLResponse, http.statusCode == 200 else { return [] }

        let payload = try JSONDecoder().decode(NetEaseLyricsResponse.self, from: lyricsData)
        guard payload.nolyric != true,
              payload.uncollected != true,
              let lrc = payload.lrc?.lyric,
              !lrc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return [] }

        let baseLyrics = parseLRC(lrc)
        let translations = payload.tlyric?.lyric.map(parseLRC) ?? []
        let romanizations = payload.romalrc?.lyric.map(parseLRC) ?? []
        return mergeSupplementalLyrics(
            into: baseLyrics,
            translations: translations,
            romanizations: romanizations
        )
    }

    private func mergeSupplementalLyrics(
        into baseLyrics: [LyricLine],
        translations: [LyricLine],
        romanizations: [LyricLine]
    ) -> [LyricLine] {
        baseLyrics.map { line in
            let translation = supplementalText(at: line.timestamp, in: translations)
            let romanization = supplementalText(at: line.timestamp, in: romanizations)
            return LyricLine(
                timestamp: line.timestamp,
                text: line.text,
                romanization: romanization == line.text ? nil : romanization,
                translation: translation == line.text ? nil : translation
            )
        }
    }

    private func supplementalText(at timestamp: TimeInterval, in lyrics: [LyricLine]) -> String? {
        guard let nearest = lyrics.min(by: {
            abs($0.timestamp - timestamp) < abs($1.timestamp - timestamp)
        }), abs(nearest.timestamp - timestamp) <= 0.5 else { return nil }

        let text = nearest.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func addingPronunciationTokens(to lyrics: [LyricLine]) -> [LyricLine] {
        let language = detectedLyricsLanguage(in: lyrics)
        guard language != .other else { return lyrics }

        return lyrics.map { line in
            let tokens: [LyricToken]?
            switch language {
            case .japanese:
                tokens = tokenizedPronunciation(
                    for: line.text,
                    localeIdentifier: "ja_JP"
                ) { token, transcription in
                    japanesePronunciation(for: token, transcription: transcription)
                }
            case .korean:
                tokens = tokenizedPronunciation(
                    for: line.text,
                    localeIdentifier: "ko_KR"
                ) { token, _ in
                    koreanPronunciation(for: token)
                }
            case .other:
                tokens = nil
            }

            return LyricLine(
                timestamp: line.timestamp,
                text: line.text,
                pronunciationTokens: tokens,
                romanization: line.romanization,
                translation: line.translation
            )
        }
    }

    private func detectedLyricsLanguage(in lyrics: [LyricLine]) -> LyricsLanguage {
        var japaneseKanaCount = 0
        var koreanCount = 0

        let lyricsText = lyrics.map(\.text).joined(separator: "\n")
        for scalar in lyricsText.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D:
                japaneseKanaCount += 1
            case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F,
                 0xAC00...0xD7AF, 0xD7B0...0xD7FF:
                koreanCount += 1
            default:
                break
            }
        }

        if koreanCount > japaneseKanaCount, koreanCount > 0 { return .korean }
        if japaneseKanaCount > 0 { return .japanese }
        return .other
    }

    private func tokenizedPronunciation(
        for text: String,
        localeIdentifier: String,
        pronunciation: (String, String?) -> String?
    ) -> [LyricToken]? {
        let cfText = text as CFString
        let fullRange = CFRange(location: 0, length: CFStringGetLength(cfText))
        let tokenizer = CFStringTokenizerCreate(
            nil,
            cfText,
            fullRange,
            kCFStringTokenizerUnitWord,
            Locale(identifier: localeIdentifier) as CFLocale
        )
        let nsText = text as NSString
        var tokens: [LyricToken] = []
        var cursor = 0
        var tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)

        while tokenType.rawValue != 0 {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            guard range.location != kCFNotFound, range.length > 0 else {
                tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
                continue
            }

            if range.location > cursor {
                appendInterveningText(
                    nsText.substring(with: NSRange(location: cursor, length: range.location - cursor)),
                    to: &tokens
                )
            }

            let tokenText = nsText.substring(
                with: NSRange(location: range.location, length: range.length)
            )
            let transcription = CFStringTokenizerCopyCurrentTokenAttribute(
                tokenizer,
                kCFStringTokenizerAttributeLatinTranscription
            ) as? String
            let reading = pronunciation(tokenText, transcription)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            tokens.append(LyricToken(
                text: tokenText,
                pronunciation: reading?.isEmpty == false ? reading : nil
            ))
            cursor = range.location + range.length
            tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }

        if cursor < nsText.length {
            appendInterveningText(nsText.substring(from: cursor), to: &tokens)
        }

        guard tokens.contains(where: { $0.pronunciation != nil }) else { return nil }
        return tokens
    }

    private func appendInterveningText(_ value: String, to tokens: inout [LyricToken]) {
        let visibleText = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !visibleText.isEmpty else { return }

        guard let previous = tokens.popLast() else {
            tokens.append(LyricToken(text: visibleText, pronunciation: nil))
            return
        }
        tokens.append(LyricToken(
            text: previous.text + visibleText,
            pronunciation: previous.pronunciation
        ))
    }

    private func japanesePronunciation(for token: String, transcription: String?) -> String? {
        switch token {
        case "は": return "wa"
        case "へ": return "e"
        case "を": return "o"
        default: break
        }

        guard let transcription else { return nil }
        let normalized = transcription
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized != token.lowercased() else { return nil }
        return normalized
    }

    private func koreanPronunciation(for token: String) -> String? {
        let scalars = Array(token.unicodeScalars)
        let syllables = scalars.map(decomposedHangulSyllable)
        guard syllables.contains(where: { $0 != nil }) else { return nil }

        var onsetOverrides: [Int: String] = [:]
        var pronunciation: [String] = []

        for index in scalars.indices {
            guard let syllable = syllables[index] else {
                pronunciation.append(String(scalars[index]))
                continue
            }

            var coda = KoreanRomanizationTables.finals[syllable.final]
            if syllable.final > 0,
               syllables.indices.contains(index + 1),
               let nextSyllable = syllables[index + 1],
               nextSyllable.initial == 11 {
                coda = KoreanRomanizationTables.liaisonCodas[syllable.final]
                onsetOverrides[index + 1] = KoreanRomanizationTables.liaisonOnsets[syllable.final]
            }

            let onset = onsetOverrides[index]
                ?? KoreanRomanizationTables.initials[syllable.initial]
            pronunciation.append(
                onset
                    + KoreanRomanizationTables.vowels[syllable.vowel]
                    + coda
            )
        }

        return pronunciation.joined(separator: " ")
    }

    private func decomposedHangulSyllable(
        _ scalar: Unicode.Scalar
    ) -> (initial: Int, vowel: Int, final: Int)? {
        guard (0xAC00...0xD7A3).contains(scalar.value) else { return nil }
        let offset = Int(scalar.value - 0xAC00)
        return (
            initial: offset / 588,
            vowel: (offset % 588) / 28,
            final: offset % 28
        )
    }

    private func bestNetEaseLyricsMatch(
        in results: [NetEaseSong],
        artist: String,
        title: String,
        album: String,
        duration: TimeInterval
    ) -> NetEaseSong? {
        let requestedAlbum = normalizedLyricsMatchText(album)

        return results.compactMap { result -> (song: NetEaseSong, score: Int)? in
            let candidateArtist = result.artists.map(\.name).joined(separator: "/")
            guard lyricsTitlesMatch(result.name, title),
                  artistsMatch(artist, candidateArtist)
            else { return nil }

            let resultDuration = result.duration / 1_000
            let durationDifference = duration > 0 ? abs(resultDuration - duration) : 0
            guard duration <= 0 || durationDifference <= 12 else { return nil }

            var score = normalizedLyricsMatchText(result.name) == normalizedLyricsMatchText(title) ? 12 : 10
            score += normalizedArtistNames(artist) == normalizedArtistNames(candidateArtist) ? 10 : 7

            let candidateAlbum = normalizedLyricsMatchText(result.album.name)
            if !requestedAlbum.isEmpty && candidateAlbum == requestedAlbum { score += 5 }
            if duration > 0 {
                if durationDifference <= 2 { score += 12 }
                else if durationDifference <= 5 { score += 8 }
                else if durationDifference <= 10 { score += 3 }
            }
            return (result, score)
        }
        .max { $0.score < $1.score }
        .flatMap { $0.score >= 20 ? $0.song : nil }
    }

    private func currentLyricsLookupContext() -> (key: LyricsLookupKey, requestArtist: String, requestTitle: String, requestAlbum: String)? {
        let requestArtist = normalizedLyricsRequestComponent(artistName)
        let requestTitle = normalizedLyricsTitle(songTitle)
        let requestAlbum = normalizedLyricsRequestComponent(album)

        let key = LyricsLookupKey(
            title: requestTitle.lowercased(),
            artist: requestArtist.lowercased(),
            album: requestAlbum.lowercased()
        )

        return key.isValid ? (key, requestArtist, requestTitle, requestAlbum) : nil
    }

    private func normalizedLyricsRequestComponent(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func normalizedLyricsTitle(_ value: String) -> String {
        var normalized = normalizedLyricsRequestComponent(value)
        let cleanupPatterns = [
            "\\s*\\((feat\\.?|ft\\.?|featuring)[^\\)]*\\)",
            "\\s*\\[(feat\\.?|ft\\.?|featuring)[^\\]]*\\]",
            "\\s*-\\s*(feat\\.?|ft\\.?|featuring)\\s+.*$",
            "\\s*\\((remaster(ed)?|live|mono|stereo)[^\\)]*\\)$",
            "\\s*\\[(remaster(ed)?|live|mono|stereo)[^\\]]*\\]$"
        ]

        for pattern in cleanupPatterns {
            normalized = normalized.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        return normalizedLyricsRequestComponent(normalized)
    }

    private func bestLyricsMatch(
        in results: [LRCLIBLyricsResult],
        artist: String,
        title: String,
        album: String,
        duration: TimeInterval
    ) -> LRCLIBLyricsResult? {
        let candidates = results
            .compactMap { result -> (result: LRCLIBLyricsResult, score: Int)? in
                guard isEligibleLyricsMatch(result, artist: artist, title: title) else { return nil }
                if duration > 0, let resultDuration = result.duration,
                   abs(resultDuration - duration) > 12 {
                    return nil
                }
                return (
                    result,
                    lyricsMatchScore(
                        for: result,
                        artist: artist,
                        title: title,
                        album: album,
                        duration: duration
                    )
                )
            }

        let synchronizedCandidates = candidates.filter {
            !($0.result.syncedLyrics ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }
        let preferredCandidates = synchronizedCandidates.isEmpty ? candidates : synchronizedCandidates

        return preferredCandidates
            .max { $0.score < $1.score }
            .flatMap { $0.score >= 20 ? $0.result : nil }
    }

    private func isEligibleLyricsMatch(
        _ result: LRCLIBLyricsResult,
        artist: String,
        title: String
    ) -> Bool {
        guard lyricsTitlesMatch(title, result.trackName),
              artistsMatch(artist, result.artistName) else { return false }

        let requestedQualifier = lyricsTitleQualifier(title)
        let candidateQualifier = lyricsTitleQualifier(result.trackName)
        return requestedQualifier.isEmpty
            || candidateQualifier.isEmpty
            || requestedQualifier == candidateQualifier
    }

    private func lyricsMatchScore(
        for result: LRCLIBLyricsResult,
        artist: String,
        title: String,
        album: String,
        duration: TimeInterval
    ) -> Int {
        let requestedTitle = normalizedLyricsMatchText(title)
        let resultTitle = normalizedLyricsMatchText(result.trackName)
        let requestedAlbum = normalizedLyricsMatchText(album)
        let resultAlbum = normalizedLyricsMatchText(result.albumName ?? "")

        var score = 0

        if resultTitle == requestedTitle {
            score += 12
        } else if canonicalLyricsTitle(result.trackName) == canonicalLyricsTitle(title) {
            score += 10
        } else if lyricsTitlesMatch(result.trackName, title) {
            score += 10
        }

        let requestedArtists = normalizedArtistNames(artist)
        let resultArtists = normalizedArtistNames(result.artistName)
        if requestedArtists == resultArtists {
            score += 10
        } else if requestedArtists.isSubset(of: resultArtists) || resultArtists.isSubset(of: requestedArtists) {
            score += 7
        }

        if !requestedAlbum.isEmpty {
            if resultAlbum == requestedAlbum {
                score += 5
            } else if canonicalLyricsTitle(result.albumName ?? "") == canonicalLyricsTitle(album) {
                score += 5
            }
        }

        if duration > 0, let resultDuration = result.duration {
            let difference = abs(resultDuration - duration)
            if difference <= 2 {
                score += 12
            } else if difference <= 5 {
                score += 8
            } else if difference <= 10 {
                score += 3
            } else if difference > 20 {
                score -= 8
            }
        }

        if !(result.syncedLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            score += 3
        }

        return score
    }

    private func normalizedLyricsMatchText(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func canonicalLyricsTitle(_ value: String) -> String {
        normalizedLyricsMatchText(
            value.replacingOccurrences(
                of: #"\s*[\(\[].*?[\)\]]\s*"#,
                with: " ",
                options: .regularExpression
            )
        )
    }

    private func lyricsTitlesMatch(_ lhs: String, _ rhs: String) -> Bool {
        !lyricsTitleAliases(lhs).isDisjoint(with: lyricsTitleAliases(rhs))
    }

    private func lyricsTitleAliases(_ value: String) -> Set<String> {
        var aliases: Set<String> = [
            normalizedLyricsMatchText(value),
            canonicalLyricsTitle(value)
        ]

        if let regex = try? NSRegularExpression(pattern: #"[\(\[]([^\)\]]+)[\)\]]"#) {
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            for match in regex.matches(in: value, range: range) where match.numberOfRanges > 1 {
                guard let aliasRange = Range(match.range(at: 1), in: value) else { continue }
                aliases.insert(normalizedLyricsMatchText(String(value[aliasRange])))
            }
        }

        aliases.remove("")
        return aliases
    }

    private func lyricsTitleQualifier(_ value: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"[\(\[]([^\)\]]+)[\)\]]"#,
            options: [.caseInsensitive]
        ) else { return "" }

        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let qualifiers = regex.matches(in: value, range: range).compactMap { match -> String? in
            guard match.numberOfRanges > 1,
                  let qualifierRange = Range(match.range(at: 1), in: value) else { return nil }
            let normalized = normalizedLyricsMatchText(String(value[qualifierRange]))
            return normalized.isEmpty ? nil : normalized
        }
        return qualifiers.joined(separator: " ")
    }

    private func normalizedArtistNames(_ value: String) -> Set<String> {
        let separators = #"\s*(?:,|&|/|;|\bfeat\.?\b|\bft\.?\b|\bfeaturing\b)\s*"#
        guard let regex = try? NSRegularExpression(pattern: separators, options: [.caseInsensitive]) else {
            return [normalizedLyricsMatchText(value)]
        }

        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let separated = regex.stringByReplacingMatches(in: value, range: range, withTemplate: "|")
        return Set(
            separated
                .split(separator: "|")
                .map {
                    normalizedLyricsMatchText(String($0))
                        .replacingOccurrences(of: " ", with: "")
                }
                .filter { !$0.isEmpty }
        )
    }

    private func artistsMatch(_ lhs: String, _ rhs: String) -> Bool {
        let lhsArtists = normalizedArtistNames(lhs)
        let rhsArtists = normalizedArtistNames(rhs)
        guard !lhsArtists.isEmpty, !rhsArtists.isEmpty else { return false }
        return lhsArtists == rhsArtists
            || lhsArtists.isSubset(of: rhsArtists)
            || rhsArtists.isSubset(of: lhsArtists)
    }

    private func applyLyricsToDisplay(_ lyrics: [LyricLine]) {
        syncedLyrics = lyrics
        currentLyricIndex = -1

        guard !lyrics.isEmpty else {
            currentLyrics = Defaults[.enableLyrics] ? "未找到歌词" : ""
            stopLyricSync()
            return
        }

        let playbackPosition = max(estimatedPlaybackPosition(), elapsedTime)
        updateCurrentLyric(for: playbackPosition)

        if currentLyricIndex == -1, let firstLine = lyrics.first?.text {
            currentLyrics = firstLine
        }

        if Defaults[.enableLyrics] && isPlaying {
            startLyricSync()
        } else {
            stopLyricSync()
        }
    }

    private func parseLRC(_ lrc: String) -> [LyricLine] {
        let lines = lrc.components(separatedBy: .newlines)
        var lyrics: [LyricLine] = []

        // Accept [m:ss], [mm:ss.xx], and millisecond timestamps such as [mm:ss.xxx].
        let pattern = "\\[(\\d{1,2}):(\\d{2})(?:\\.(\\d{1,3}))?\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }

        for line in lines {
            let nsLine = line as NSString
            let fullRange = NSRange(location: 0, length: nsLine.length)
            if let match = regex.firstMatch(in: line, options: [], range: fullRange) {
                let minRange = match.range(at: 1)
                let secRange = match.range(at: 2)
                let fractionRange = match.range(at: 3)

                let minStr = minRange.location != NSNotFound ? nsLine.substring(with: minRange) : "0"
                let secStr = secRange.location != NSNotFound ? nsLine.substring(with: secRange) : "0"
                let fractionString = (fractionRange.location != NSNotFound) ? nsLine.substring(with: fractionRange) : "0"

                let minutes = Double(minStr) ?? 0
                let seconds = Double(secStr) ?? 0
                let fraction = Double("0.\(fractionString)") ?? 0
                let timestamp = minutes * 60 + seconds + fraction

                let textStart = match.range.location + match.range.length
                if textStart <= nsLine.length {
                    let text = simplifiedChinese(
                        nsLine.substring(from: textStart).trimmingCharacters(in: .whitespaces)
                    )
                    if !text.isEmpty {
                        lyrics.append(LyricLine(timestamp: timestamp, text: text))
                    }
                }
            }
        }

        return lyrics.sorted(by: { $0.timestamp < $1.timestamp })
    }

    func updateCurrentLyric(for elapsedTime: TimeInterval) {
        guard !syncedLyrics.isEmpty else { return }

        let displayTime = elapsedTime + Self.lyricDisplayLeadTime
        var lowerBound = 0
        var upperBound = syncedLyrics.count

        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if syncedLyrics[middle].timestamp <= displayTime {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        let newIndex = lowerBound - 1

        if newIndex != currentLyricIndex {
            currentLyricIndex = newIndex
            if newIndex >= 0 && newIndex < syncedLyrics.count {
                currentLyrics = syncedLyrics[newIndex].text
            }
        }
    }

    private func simplifiedChinese(_ text: String) -> String {
        text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text
    }

    // Start a background task that periodically updates the displayed lyric
    private func startLyricSync() {
        guard Defaults[.enableLyrics], !syncedLyrics.isEmpty, isPlaying else { return }
        if lyricSyncTask != nil { return }

        lyricSyncTask = Task { [weak self] in
            guard let self = self else { return }
            while !Task.isCancelled {
                // Compute estimated playback position and update lyric
                let position = self.estimatedPlaybackPosition()
                await MainActor.run {
                    self.updateCurrentLyric(for: position)
                }

                try? await Task.sleep(nanoseconds: Self.lyricSyncIntervalNanoseconds)
            }
        }
    }

    private func stopLyricSync() {
        lyricSyncTask?.cancel()
        lyricSyncTask = nil
    }

    // MARK: - Video Artwork

    func fetchVideoArtwork() {
        guard Defaults[.lockScreenMusicFullscreenVideoArtwork] else {
            videoArtworkURL = nil
            return
        }
        // Se il player non è Apple Music, non toccare videoArtworkURL:
        // SpotifyController gestisce il canvas in modo autonomo tramite liveArtworkURL.
        guard bundleIdentifier == "com.apple.Music" else {
            return
        }

        let title = songTitle
        let artist = artistName

        Task {
            let url = await AnimatedArtworkManager.shared.fetchAnimatedArtworkURL(
                title: title, artist: artist
            )
            await MainActor.run {
                self.videoArtworkURL = url
            }
        }
    }

    func toggleLyrics() {
        // Toggle the UI state first so the views can react immediately.
        showLyrics.toggle()

        // If lyrics are requested to be shown but we don't have any yet,
        // show a loading placeholder and start fetching asynchronously.
        if showLyrics && syncedLyrics.isEmpty {
            // Provide immediate feedback so the UI can show a loading state.
            currentLyrics = "正在加载歌词..."

            Task {
                await fetchLyrics()

                // If fetch completed but no lyrics were found, show a friendly message.
                await MainActor.run {
                    if self.syncedLyrics.isEmpty && self.currentLyrics.isEmpty {
                        self.currentLyrics = "未找到歌词"
                    }
                }
            }
        }
    }
}

// MARK: - Media Branding

extension MusicManager {
    var brandAccentColor: Color {
        Self.brandAccentColor(for: Defaults[.mediaController], bundleIdentifier: bundleIdentifier)
    }

    private static func brandAccentColor(for controller: MediaControllerType, bundleIdentifier: String?) -> Color {
        switch controller {
        case .appleMusic:
            return appleMusicPink
        case .spotify:
            return spotifyGreen
        case .amazonMusic:
            return amazonOrange
        case .nowPlaying:
            if let bundleIdentifier,
               let bundleColor = brandAccentColor(forBundleIdentifier: bundleIdentifier) {
                return bundleColor
            }
            fallthrough
        case .youtubeMusic:
            return .accentColor
        }
    }

    private static func brandAccentColor(forBundleIdentifier bundleIdentifier: String) -> Color? {
        switch bundleIdentifier {
        case "com.apple.Music":
            return appleMusicPink
        case "com.spotify.client":
            return spotifyGreen
        case AmazonMusicController.bundleIdentifier:
            return amazonOrange
        default:
            return nil
        }
    }

    private static let appleMusicPink = Color(red: 0.999, green: 0.171, blue: 0.331)
    private static let spotifyGreen = Color(red: 0.0, green: 0.857, blue: 0.302)
    private static let amazonOrange = Color(red: 1.0, green: 0.6, blue: 0.0)
}

// MARK: - Album Art Flip Helper

private struct AlbumArtFlipModifier: ViewModifier {
    let angle: Double

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(
                .degrees(angle),
                axis: (x: 0, y: 1, z: 0),
                anchor: .center,
                anchorZ: 0,
                perspective: 0.5
            )
            // Counter-rotate the content so the image never appears mirrored.
            // At odd multiples of 180° the 3D rotation mirrors along X;
            // applying an opposite scaleEffect cancels that out.
            .scaleEffect(x: cosineSign(for: angle), y: 1)
    }

    /// Returns +1 when the front face is showing, −1 when the back face is showing.
    private func cosineSign(for degrees: Double) -> CGFloat {
        let cos = Darwin.cos(degrees * .pi / 180)
        // Use a small tolerance to avoid flickering exactly at 90°/270°.
        if cos > 0.001 { return 1 }
        if cos < -0.001 { return -1 }
        return degrees.truncatingRemainder(dividingBy: 360) >= 0 ? -1 : 1
    }
}

extension View {
    func albumArtFlip(angle: Double) -> some View {
        modifier(AlbumArtFlipModifier(angle: angle))
    }
}
