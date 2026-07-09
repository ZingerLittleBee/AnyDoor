import Foundation

struct QuicklinkInlineArgumentResolver {
    struct Match: Equatable {
        let quicklinkID: UUID
        let title: String
        let argument: String
        let substitutedLink: String
    }

    static func resolve(query: String, candidates: [QuicklinkTemplateCandidate]) -> Match? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var best: (match: Match, triggerLength: Int)?
        for template in candidates {
            guard QuicklinkDestination.isSearchTemplate(link: template.link) else { continue }

            let triggers = triggerCandidates(for: template, query: trimmed)
            for candidate in triggers {
                guard let substituted = QuicklinkOpener.substitutedTemplateLink(
                    link: template.link,
                    argument: candidate.argument
                ) else { continue }
                let match = Match(
                    quicklinkID: template.id,
                    title: template.title,
                    argument: candidate.argument,
                    substitutedLink: substituted
                )
                if best.map({ candidate.triggerLength > $0.triggerLength }) ?? true {
                    best = (match, candidate.triggerLength)
                }
            }
        }
        return best?.match
    }

    private static func triggerCandidates(
        for template: QuicklinkTemplateCandidate,
        query: String
    ) -> [(argument: String, triggerLength: Int)] {
        var candidates: [(argument: String, triggerLength: Int)] = []
        if let keyword = keywordCandidate(for: template, query: query) {
            candidates.append(keyword)
        }
        if let displayName = displayNameCandidate(for: template, query: query) {
            candidates.append(displayName)
        }
        return candidates
    }

    private static func keywordCandidate(
        for template: QuicklinkTemplateCandidate,
        query: String
    ) -> (argument: String, triggerLength: Int)? {
        guard let split = query.firstIndex(where: \.isWhitespace) else { return nil }
        let firstToken = String(query[..<split])
        guard !firstToken.isEmpty else { return nil }
        guard let keyword = template.keyword,
              keyword.compare(firstToken, options: [.caseInsensitive]) == .orderedSame else { return nil }
        let argument = query[split...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !argument.isEmpty else { return nil }
        return (argument, firstToken.count)
    }

    private static func displayNameCandidate(
        for template: QuicklinkTemplateCandidate,
        query: String
    ) -> (argument: String, triggerLength: Int)? {
        let title = template.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, query.count > title.count else { return nil }
        let boundary = query.index(query.startIndex, offsetBy: title.count)
        guard String(query[..<boundary]).compare(title, options: [.caseInsensitive]) == .orderedSame,
              query[boundary].isWhitespace else { return nil }
        let argument = query[boundary...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !argument.isEmpty else { return nil }
        return (argument, title.count)
    }
}
