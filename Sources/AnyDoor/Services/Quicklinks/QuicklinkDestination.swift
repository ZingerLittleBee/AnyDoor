import Foundation

enum QuicklinkDestination: Equatable {
    enum FileExistence: Equatable {
        case none
        case file
        case directory
    }

    case web(URL)
    case deeplink(URL)
    case file(URL)
    case folder(URL)
    case missingFileSystem(URL)
    case searchTemplate(String)
    case unsupported(String)

    var isSearchTemplate: Bool {
        if case .searchTemplate = self { return true }
        return false
    }

    static func classify(link: String) -> QuicklinkDestination {
        classify(link: link, fileExists: fileExistence(atPath:))
    }

    static func classify(
        link: String,
        fileExists: (String) -> FileExistence
    ) -> QuicklinkDestination {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unsupported(link) }
        if isSearchTemplate(link: trimmed) {
            return .searchTemplate(trimmed)
        }

        if let fileURL = fileURL(from: trimmed) {
            return fileSystemDestination(for: fileURL, fileExists: fileExists)
        }

        if let url = schemeLessWebURL(from: trimmed) {
            return .web(url)
        }

        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            return .unsupported(trimmed)
        }

        if url.isFileURL {
            return fileSystemDestination(for: url, fileExists: fileExists)
        }

        switch scheme {
        case "http", "https":
            return .web(url)
        default:
            return .deeplink(url)
        }
    }

    static func isSearchTemplate(link: String) -> Bool {
        link.trimmingCharacters(in: .whitespacesAndNewlines).contains("{query}")
    }

    private static func fileURL(from raw: String) -> URL? {
        if raw.hasPrefix("~/") || raw == "~" {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        }
        if raw.hasPrefix("/") {
            return URL(fileURLWithPath: raw)
        }
        return nil
    }

    private static func fileSystemDestination(
        for url: URL,
        fileExists: (String) -> FileExistence
    ) -> QuicklinkDestination {
        switch fileExists(url.path) {
        case .none:
            return .missingFileSystem(url)
        case .file:
            return .file(url)
        case .directory:
            return .folder(url)
        }
    }

    private static func fileExistence(atPath path: String) -> FileExistence {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .none
        }
        return isDirectory.boolValue ? .directory : .file
    }

    private static func schemeLessWebURL(from raw: String) -> URL? {
        guard !raw.contains("://") else { return nil }
        guard raw.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        guard !raw.hasPrefix(".") && !raw.hasPrefix("-") else { return nil }

        let hostPort = raw.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? raw
        guard !hostPort.isEmpty else { return nil }

        let hasExplicitPort = explicitPort(in: hostPort) != nil
        let lowerHost = hostPort.lowercased()
        let isLikelyHost = lowerHost == "localhost"
            || lowerHost.hasPrefix("localhost:")
            || hostPort.contains(".")
            || hasExplicitPort
        guard isLikelyHost else { return nil }

        let scheme = hasExplicitPort ? "http" : "https"
        return URL(string: "\(scheme)://\(raw)")
    }

    private static func explicitPort(in hostPort: String) -> Int? {
        guard let colon = hostPort.lastIndex(of: ":") else { return nil }
        let afterColon = hostPort[hostPort.index(after: colon)...]
        guard !afterColon.isEmpty, afterColon.allSatisfy(\.isNumber) else { return nil }
        return Int(afterColon)
    }
}
