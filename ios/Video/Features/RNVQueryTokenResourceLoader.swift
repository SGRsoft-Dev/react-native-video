//
//  RNVQueryTokenResourceLoader.swift
//  react-native-video
//
//  Appends a raw `key=value` query token to every request AVPlayer makes for an HLS asset.
//
//  AVPlayer offers no request interceptor, and HLS child URIs are resolved relatively to their
//  playlist, so RFC 3986 drops the manifest's query before it can reach the segments. The only
//  hook is AVAssetResourceLoader, which fires for custom URL schemes.
//
//  So the asset URL is given a custom scheme and this delegate handles it:
//    - playlists (.m3u8) are fetched here and their body rewritten so that every URI inside is
//      absolute; nested playlists keep the custom scheme (to be intercepted in turn) while
//      segments, keys and init sections become plain https carrying the token.
//    - everything else is answered with a redirect rather than proxied.
//
//  Media bytes therefore never pass through this delegate: AVPlayer loads segments directly over
//  https, keeping byte-range requests, caching and throughput intact.
//
//  FairPlay is unaffected because it goes through AVContentKeySession, not the resource loader.
//

import AVFoundation
import Foundation

class RNVQueryTokenResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    /// Delegate callbacks run here; AVFoundation requires a queue we own.
    static let queue = DispatchQueue(label: "RNVQueryTokenResourceLoaderQueue")
    /// Key for the associated object that keeps this delegate alive alongside the asset
    /// (AVAssetResourceLoader holds its delegate weakly).
    static var assetKey: UInt8 = 0

    /// Scheme prefix that marks a URL as ours. The real scheme is kept after the dash so it can
    /// be restored (`rnvtoken-https` -> `https`).
    static let schemePrefix = "rnvtoken-"

    private let token: String
    private let headers: [String: String]
    private let session: URLSession

    /// - Parameter token: raw `key=value`; any leading `?`/`&` is stripped.
    init?(token: String?, headers: [String: Any]?) {
        guard let raw = token?.trimmingCharacters(in: CharacterSet(charactersIn: "?& ")),
              !raw.isEmpty else { return nil }
        self.token = raw
        var stringHeaders: [String: String] = [:]
        headers?.forEach { key, value in stringHeaders[key] = String(describing: value) }
        self.headers = stringHeaders
        session = URLSession(configuration: .default)
        super.init()
    }

    /// Rewrites `https://host/x.m3u8` into `rnvtoken-https://host/x.m3u8` so the loader sees it.
    static func markURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme,
              !scheme.hasPrefix(schemePrefix) else { return url }
        components.scheme = schemePrefix + scheme
        return components.url ?? url
    }

    /// Inverse of `markURL`, plus the token.
    private func realURL(from url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme,
              scheme.hasPrefix(Self.schemePrefix) else { return nil }
        components.scheme = String(scheme.dropFirst(Self.schemePrefix.count))
        return Self.appendToken(components.url, token: token)
    }

    /// Appends the token, choosing `?` or `&`, and skips when it is already present.
    static func appendToken(_ url: URL?, token: String) -> URL? {
        guard let url else { return nil }
        let text = url.absoluteString
        // split off the fragment so the token lands before it
        let parts = text.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let base = String(parts[0])
        let fragment = parts.count > 1 ? "#" + String(parts[1]) : ""
        if base.contains(token) { return url }
        let separator = base.contains("?") ? "&" : "?"
        return URL(string: base + separator + token + fragment) ?? url
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(
        _: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let requestedURL = loadingRequest.request.url,
              let target = realURL(from: requestedURL) else { return false }

        // Only playlists need their body rewritten. Anything else is redirected untouched so the
        // player keeps talking to the CDN directly.
        guard isPlaylist(target) else {
            redirect(loadingRequest, to: target)
            return true
        }

        var request = URLRequest(url: target)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                loadingRequest.finishLoading(with: error)
                return
            }
            guard let data, let text = String(data: data, encoding: .utf8) else {
                loadingRequest.finishLoading(with: RNVQueryTokenError.unreadablePlaylist)
                return
            }

            let rewritten = self.rewritePlaylist(text, baseURL: target)
            guard let body = rewritten.data(using: .utf8) else {
                loadingRequest.finishLoading(with: RNVQueryTokenError.unreadablePlaylist)
                return
            }

            if let contentInformation = loadingRequest.contentInformationRequest {
                contentInformation.contentType = "public.m3u-playlist"
                contentInformation.contentLength = Int64(body.count)
                contentInformation.isByteRangeAccessSupported = false
            }
            // a rewritten playlist has a different length than the origin's, so honour the
            // requested window rather than handing back the whole body blindly
            if let dataRequest = loadingRequest.dataRequest {
                let offset = Int(dataRequest.requestedOffset)
                guard offset <= body.count else {
                    loadingRequest.finishLoading(with: RNVQueryTokenError.unreadablePlaylist)
                    return
                }
                let length = min(dataRequest.requestedLength, body.count - offset)
                dataRequest.respond(with: body.subdata(in: offset..<(offset + length)))
            }
            _ = response
            loadingRequest.finishLoading()
        }
        task.resume()
        return true
    }

    private func redirect(_ loadingRequest: AVAssetResourceLoadingRequest, to url: URL) {
        let request = URLRequest(url: url)
        loadingRequest.redirect = request
        loadingRequest.response = HTTPURLResponse(
            url: url,
            statusCode: 302,
            httpVersion: nil,
            headerFields: nil
        )
        loadingRequest.finishLoading()
    }

    // MARK: - Playlist rewriting

    private func isPlaylist(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return path.hasSuffix(".m3u8") || path.hasSuffix(".m3u")
    }

    /// Makes every URI in the playlist absolute and token-bearing.
    ///
    /// Nested playlists keep the custom scheme so this delegate sees them again; media URIs are
    /// left on https so AVPlayer fetches them itself.
    func rewritePlaylist(_ text: String, baseURL: URL) -> String {
        var output: [String] = []
        output.reserveCapacity(text.count / 40)

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                output.append(line)
            } else if trimmed.hasPrefix("#") {
                output.append(rewriteTagURIs(in: line, baseURL: baseURL))
            } else {
                // a bare line is a variant playlist or a segment
                output.append(resolve(trimmed, baseURL: baseURL))
            }
        }
        return output.joined(separator: "\n")
    }

    /// Rewrites the `URI="..."` attribute carried by tags such as EXT-X-MEDIA, EXT-X-KEY,
    /// EXT-X-MAP, EXT-X-PART and EXT-X-PRELOAD-HINT.
    private func rewriteTagURIs(in line: String, baseURL: URL) -> String {
        guard let range = line.range(of: "URI=\"") else { return line }
        let valueStart = range.upperBound
        guard let closing = line[valueStart...].firstIndex(of: "\"") else { return line }
        let uri = String(line[valueStart..<closing])
        let replacement = resolve(uri, baseURL: baseURL)
        return line.replacingCharacters(in: valueStart..<closing, with: replacement)
    }

    private func resolve(_ uri: String, baseURL: URL) -> String {
        guard let absolute = URL(string: uri, relativeTo: baseURL)?.absoluteURL else { return uri }
        guard let tokenized = Self.appendToken(absolute, token: token) else { return uri }
        // nested playlists must come back through this delegate; media must not
        return isPlaylist(absolute) ? Self.markURL(tokenized).absoluteString : tokenized.absoluteString
    }
}

enum RNVQueryTokenError: Error {
    case unreadablePlaylist
}
