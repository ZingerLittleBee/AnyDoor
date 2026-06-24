import Foundation
import SwiftData

/// One persisted translation, written when a stream provider finishes
/// successfully. Powers the favorites + history panel. The fifth `@Model` in
/// the app's ModelContainer schema; all fields keep inline scalar defaults so
/// SwiftData lightweight migration can backfill existing stores.
@Model
final class TranslationRecord {
    var id: String = ""
    var createdAt: Date = Date()
    var sourceText: String = ""
    var translatedText: String = ""
    var sourceLangCode: String = ""
    var targetLangCode: String = ""
    var serviceID: String = ""
    var serviceName: String = ""
    var isFavorite: Bool = false
    /// Identifies the translation run this record belongs to: every service result
    /// from one `translate()` shares it, so the history view can merge a run into a
    /// single card. Empty on legacy rows, which each form their own one-record card.
    var runID: String = ""

    init(
        sourceText: String,
        translatedText: String,
        sourceLangCode: String,
        targetLangCode: String,
        serviceID: String,
        serviceName: String,
        isFavorite: Bool = false,
        createdAt: Date = Date(),
        runID: String = ""
    ) {
        self.id = UUID().uuidString
        self.createdAt = createdAt
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.sourceLangCode = sourceLangCode
        self.targetLangCode = targetLangCode
        self.serviceID = serviceID
        self.serviceName = serviceName
        self.isFavorite = isFavorite
        self.runID = runID
    }
}
