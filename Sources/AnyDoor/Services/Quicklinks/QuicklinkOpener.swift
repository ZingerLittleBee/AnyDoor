import AppKit
import Foundation

enum QuicklinkOpenFailure: Equatable {
    case emptyLink
    case missingFileSystem(URL)
    case missingArgument
    case unsupported(String)
}

enum QuicklinkOpenWarning: Equatable {
    case openWithAppMissing(String)
}

struct QuicklinkOpenPlan: Equatable {
    enum Action: Equatable {
        case open(URL)
        case openWithApplication(URL, applicationURL: URL)
        case fail(QuicklinkOpenFailure)
    }

    let action: Action
    let warning: QuicklinkOpenWarning?

    static func open(_ url: URL, warning: QuicklinkOpenWarning? = nil) -> QuicklinkOpenPlan {
        QuicklinkOpenPlan(action: .open(url), warning: warning)
    }

    static func openWithApplication(_ url: URL, applicationURL: URL) -> QuicklinkOpenPlan {
        QuicklinkOpenPlan(action: .openWithApplication(url, applicationURL: applicationURL), warning: nil)
    }

    static func fail(_ failure: QuicklinkOpenFailure) -> QuicklinkOpenPlan {
        QuicklinkOpenPlan(action: .fail(failure), warning: nil)
    }
}

@MainActor
final class QuicklinkOpener {
    static let shared = QuicklinkOpener()

    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    nonisolated static func plan(
        link: String,
        argument: String? = nil,
        openWithBundleID: String? = nil,
        applicationURLForBundleID: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    ) -> QuicklinkOpenPlan {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .fail(.emptyLink) }

        let plannedLink: String
        if QuicklinkDestination.isSearchTemplate(link: trimmed) {
            guard let encoded = encodedArgument(argument), !encoded.isEmpty else {
                return .fail(.missingArgument)
            }
            plannedLink = trimmed.replacingOccurrences(of: "{query}", with: encoded)
        } else {
            plannedLink = trimmed
        }

        switch QuicklinkDestination.classify(link: plannedLink) {
        case .web(let url), .deeplink(let url), .file(let url), .folder(let url):
            return planOpen(url, openWithBundleID: openWithBundleID, applicationURLForBundleID: applicationURLForBundleID)
        case .missingFileSystem(let url):
            return .fail(.missingFileSystem(url))
        case .searchTemplate:
            assertionFailure("Substituted Quicklink links should not remain Search Templates.")
            return .fail(.missingArgument)
        case .unsupported(let raw):
            return .fail(.unsupported(raw))
        }
    }

    func open(_ quicklink: Quicklink, argument: String? = nil) {
        let plan = Self.plan(
            link: quicklink.link,
            argument: argument,
            openWithBundleID: quicklink.openWithBundleID
        )
        execute(plan)
    }

    func execute(_ plan: QuicklinkOpenPlan) {
        if let warning = plan.warning {
            ToastPresenter.shared.show(.info(toastMessage(for: warning)))
        }

        switch plan.action {
        case .open(let url):
            if !workspace.open(url) {
                ToastPresenter.shared.show(.failure(L(.toastQuicklinkOpenFailed)))
            }
        case .openWithApplication(let url, let applicationURL):
            let configuration = NSWorkspace.OpenConfiguration()
            workspace.open([url], withApplicationAt: applicationURL, configuration: configuration)
        case .fail(let failure):
            ToastPresenter.shared.show(.failure(toastMessage(for: failure)))
        }
    }

    nonisolated private static func planOpen(
        _ url: URL,
        openWithBundleID: String?,
        applicationURLForBundleID: (String) -> URL?
    ) -> QuicklinkOpenPlan {
        guard let bundleID = openWithBundleID, !bundleID.isEmpty else {
            return .open(url)
        }
        guard let applicationURL = applicationURLForBundleID(bundleID) else {
            return .open(url, warning: .openWithAppMissing(bundleID))
        }
        return .openWithApplication(url, applicationURL: applicationURL)
    }

    nonisolated private static func encodedArgument(_ argument: String?) -> String? {
        guard let argument else { return nil }
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=")
        return trimmed.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    private func toastMessage(for failure: QuicklinkOpenFailure) -> String {
        switch failure {
        case .emptyLink, .unsupported, .missingArgument:
            return L(.toastQuicklinkOpenFailed)
        case .missingFileSystem:
            return L(.toastQuicklinkMissingFile)
        }
    }

    private func toastMessage(for warning: QuicklinkOpenWarning) -> String {
        switch warning {
        case .openWithAppMissing:
            return L(.toastQuicklinkOpenWithMissing)
        }
    }
}
