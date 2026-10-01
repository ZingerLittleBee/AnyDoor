import ClipboardHistory
import XCTest
@testable import AnyDoor

@MainActor
final class ClipboardHistoryCaptureNoticePresenterTests: XCTestCase {
    func testEachNoticeShowsItsOwnLocalizedFailureToast() {
        let previous = LocalizationManager.shared.preference
        defer { LocalizationManager.shared.preference = previous }
        let expectations:
            [(LanguagePreference, ClipboardHistoryCaptureNotice, String)] = [
                (.en, .tooLarge, "Too large to save to Clipboard History"),
                (.en, .captureFailed, "Couldn’t save to Clipboard History"),
                (.zh, .tooLarge, "内容过大，未保存到剪贴板历史"),
                (.zh, .captureFailed, "未能保存到剪贴板历史"),
            ]

        for (language, notice, message) in expectations {
            LocalizationManager.shared.preference = language
            var shown: [ToastStyle] = []

            ClipboardHistoryCaptureNoticePresenter.present(notice) {
                shown.append($0)
            }

            XCTAssertEqual(shown.count, 1, "\(notice) in \(language)")
            guard case .failure(let text)? = shown.first else {
                XCTFail("\(notice) must show a failure toast")
                continue
            }
            XCTAssertEqual(text, message, "\(notice) in \(language)")
        }
    }
}
