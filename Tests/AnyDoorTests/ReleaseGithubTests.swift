import Foundation
import XCTest

final class ReleaseGithubTests: XCTestCase {
    func testCreateRetriesAndRecoversLostResponseWithoutDuplicateDraft() throws {
        for mode in ["createTransient", "createLost"] {
            try run(mode: mode, body: """
                release_github_retry create release_github_create_draft v4.2.5 --draft
                test "$(cat "$STATE/draft")" = true
                test "$(cat "$STATE/create-count")" = "${EXPECTED_CREATES}"
                """, environment: ["EXPECTED_CREATES": mode == "createLost" ? "1" : "2"])
        }
    }

    func testUploadRecoversCompletedAndPartialUploadsBeforePublishing() throws {
        for mode in ["uploadLost", "uploadPartial"] {
            try run(mode: mode, body: """
                printf true > "$STATE/draft"
                printf 'release payload' > "$STATE/app.zip"
                release_github_retry upload release_github_upload_asset v4.2.5 "$STATE/app.zip"
                test "$(cat "$STATE/asset")" = uploaded:15
                test "$(cat "$STATE/upload-count")" = "$EXPECTED_UPLOADS"
                release_github_retry publish release_github_publish v4.2.5
                test "$(cat "$STATE/draft")" = false
                """, environment: ["EXPECTED_UPLOADS": mode == "uploadLost" ? "1" : "2"])
        }
    }

    func testPublishRetriesHandshakeFailureAndAcceptsLostResponse() throws {
        for mode in ["publishTransient", "publishLost", "verifyTransient"] {
            try run(mode: mode, body: """
                printf true > "$STATE/draft"
                release_github_retry publish release_github_publish v4.2.5
                test "$(cat "$STATE/draft")" = false
                test "$(cat "$STATE/edit-count")" = "$EXPECTED_EDITS"
                """, environment: ["EXPECTED_EDITS": mode == "publishTransient" ? "2" : "1"])
        }
    }

    func testPersistentFailureIsBoundedAndLeavesDraftRecoverable() throws {
        try run(mode: "publishPermanent", body: """
            printf true > "$STATE/draft"
            if release_github_retry publish release_github_publish v4.2.5; then exit 90; fi
            test "$(cat "$STATE/draft")" = true
            test "$(cat "$STATE/edit-count")" = 4
            test "$(cat "$STATE/delays")" = "$(printf '2\n4\n8')"
            """)
    }

    func testPublishedReleaseIsNeverReuploadedOrRepublished() throws {
        try run(mode: "normal", body: """
            printf false > "$STATE/draft"
            printf 'release payload' > "$STATE/app.zip"
            release_github_retry publish release_github_publish v4.2.5
            if release_github_retry upload release_github_upload_asset v4.2.5 "$STATE/app.zip"; then exit 90; fi
            test ! -e "$STATE/edit-count"
            test ! -e "$STATE/upload-count"
            test "$(cat "$STATE/draft")" = false
            """)
    }

    private func run(
        mode: String,
        body: String,
        environment: [String: String] = [:]
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "set -euo pipefail\nsource \"$1\"\n" + Self.githubFixture + "\n" + body,
                             "--", root.appendingPathComponent("scripts/release-github.sh").path]
        process.environment = ProcessInfo.processInfo.environment
            .merging(environment) { _, new in new }
            .merging(["STATE": directory.path, "MODE": mode]) { _, new in new }
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let error = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, "\(mode): \(error)")
    }

    // Only the external GitHub CLI and the backoff clock are replaced. The real
    // publication functions operate against persistent simulated remote state.
    private static let githubFixture = #"""
    sleep() { printf '%s\n' "$1" >> "$STATE/delays"; }
    gh() {
        local operation="$2" count=0
        if [[ -f "$STATE/$operation-count" ]]; then
            count="$(cat "$STATE/$operation-count")"
        fi
        count=$((count + 1))
        printf '%s' "$count" > "$STATE/$operation-count"
        case "$operation" in
            create)
                if [[ "$MODE" == createTransient && "$count" -eq 1 ]]; then return 1; fi
                [[ ! -f "$STATE/draft" ]] || return 1
                printf true > "$STATE/draft"
                [[ "$MODE" != createLost ]]
                ;;
            view)
                [[ -f "$STATE/draft" ]] || return 1
                if [[ "$MODE" == verifyTransient && "$count" -eq 2 ]]; then return 1; fi
                if [[ "$*" == *'--json assets'* ]]; then
                    if [[ -f "$STATE/asset" ]]; then cat "$STATE/asset"; fi
                else
                    cat "$STATE/draft"
                fi
                ;;
            upload)
                [[ "$(cat "$STATE/draft")" == true ]] || return 1
                if [[ "$MODE" == uploadPartial && "$count" -eq 1 ]]; then
                    printf starter:0 > "$STATE/asset"
                    return 1
                fi
                printf 'uploaded:%s' "$(( $(wc -c < "$4") ))" > "$STATE/asset"
                [[ "$MODE" != uploadLost || "$count" -ne 1 ]]
                ;;
            edit)
                if [[ "$MODE" == publishPermanent || ( "$MODE" == publishTransient && "$count" -eq 1 ) ]]; then
                    printf 'TLS handshake timeout\n' >&2
                    return 1
                fi
                printf false > "$STATE/draft"
                [[ "$MODE" != publishLost ]]
                ;;
            *) return 99 ;;
        esac
    }
    """#
}
