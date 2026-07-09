import Testing
@testable import AnyDoor

/// Pins the contracts every built-in Quicklink template must satisfy, so a bad
/// preset can't silently ship: a template whose link is not a Search Template
/// would open with an empty argument, a duplicate id breaks `ForEach`
/// identity in the menu, and a duplicate keyword makes two presets collide the
/// moment the second is saved.
struct QuicklinkTemplateCatalogTests {

    @Test
    func everyTemplateLinkIsASearchTemplate() {
        for template in QuicklinkTemplateCatalog.all {
            #expect(
                QuicklinkDestination.isSearchTemplate(link: template.link),
                "\(template.id) link is not a {query} search template"
            )
            #expect(
                QuicklinkDestination.classify(link: template.link).isSearchTemplate,
                "\(template.id) link does not classify as a search template"
            )
        }
    }

    @Test
    func templateIDsAreUnique() {
        let ids = QuicklinkTemplateCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count, "duplicate template id in the catalog")
    }

    @Test
    func suggestedKeywordsAreUniqueCaseInsensitively() {
        let keywords = QuicklinkTemplateCatalog.all
            .compactMap { $0.keyword?.lowercased() }
        #expect(Set(keywords).count == keywords.count, "duplicate suggested keyword in the catalog")
    }

    @Test
    func catalogIsNotEmpty() {
        #expect(!QuicklinkTemplateCatalog.all.isEmpty)
    }
}
