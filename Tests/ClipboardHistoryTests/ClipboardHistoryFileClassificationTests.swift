import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import ClipboardHistory

final class ClipboardHistoryFileClassificationTests: XCTestCase {
    func testMovieAndVideoTypesRetainTheFileFacet() {
        for type in [UTType.movie, .video, .mpeg4Movie, .quickTimeMovie] {
            XCTAssertEqual(
                ClipboardHistoryFileClassification.facets(
                    resourceType: type.identifier, capturedPath: "/missing/clip"
                ),
                [.file, .video]
            )
        }
    }

    func testMissingOrGenericTypesUseVideoExtensionsWithoutOpeningFiles() {
        for type in [nil, UTType.data.identifier, UTType.item.identifier] {
            for suffix in ["mp4", "MOV", "m4v", "avi", "mkv", "webm"] {
                XCTAssertEqual(
                    ClipboardHistoryFileClassification.facets(
                        resourceType: type, capturedPath: "/missing/clip.\(suffix)"
                    ),
                    [.file, .video], suffix
                )
            }
        }
    }

    func testDeclaredNonVideoTypesOverrideTheExtension() {
        for type in [UTType.audio, .plainText, .folder] {
            XCTAssertEqual(
                ClipboardHistoryFileClassification.facets(
                    resourceType: type.identifier, capturedPath: "/missing/clip.mp4"
                ),
                [.file]
            )
        }
        XCTAssertEqual(
            ClipboardHistoryFileClassification.facets(
                resourceType: UTType.gif.identifier, capturedPath: "/missing/clip.gif"
            ),
            [.file, .image]
        )
        XCTAssertEqual(
            ClipboardHistoryFileClassification.facets(
                resourceType: nil, capturedPath: "/missing/sound.mp3"
            ),
            [.file]
        )
    }
}
