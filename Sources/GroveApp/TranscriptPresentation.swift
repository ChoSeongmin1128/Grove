import Foundation

struct TranscriptDisplayRow: Identifiable {
    let utterance: DocumentUtterance
    let continuesPrevious: Bool
    var id: UUID { utterance.id }
}

enum TranscriptPresentation {
    static func rows(in document: TranscriptDocument, query: String = "", speakerFilter: String = "all",
                     onlyUtteranceIDs: Set<UUID>? = nil) -> [TranscriptDisplayRow] {
        let ordered = document.utterances.enumerated().sorted {
            $0.element.startTime == $1.element.startTime
                ? $0.offset < $1.offset : $0.element.startTime < $1.element.startTime
        }.map(\.element)
        var rows: [TranscriptDisplayRow] = []
        var previousVisibleIndex: Int?
        for (index, utterance) in ordered.enumerated() {
            guard onlyUtteranceIDs?.contains(utterance.id) ?? true else { continue }
            let matchesSpeaker = speakerFilter == "all"
                || (speakerFilter == "unassigned" && utterance.speakerID == nil)
                || utterance.speakerID?.uuidString == speakerFilter
            guard matchesSpeaker && (query.isEmpty || utterance.displayedText.localizedCaseInsensitiveContains(query)
                || document.speakerName(for: utterance).localizedCaseInsensitiveContains(query)) else { continue }
            let consecutive = previousVisibleIndex == index - 1 && index > 0
                && isContinuation(utterance, after: ordered[index - 1])
            rows.append(TranscriptDisplayRow(utterance: utterance, continuesPrevious: consecutive))
            previousVisibleIndex = index
        }
        return rows
    }

    private static func isContinuation(_ current: DocumentUtterance, after previous: DocumentUtterance) -> Bool {
        guard let speakerID = current.speakerID, speakerID == previous.speakerID,
              current.sourceChannelID == previous.sourceChannelID else { return false }
        let gap = current.startTime - previous.endTime
        return gap >= 0 && gap <= 2
    }

    // UI-only precision; stored boundaries and export formatting are unchanged.
    static func timestamp(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max / 100) else { return "—" }
        let hundredths = Int((seconds * 100).rounded())
        let whole = hundredths / 100
        let fraction = hundredths % 100
        if whole >= 3600 {
            return String(format: "%02d:%02d:%02d.%02d", whole / 3600, whole / 60 % 60, whole % 60, fraction)
        }
        return String(format: "%02d:%02d.%02d", whole / 60, whole % 60, fraction)
    }

    static func timeRange(_ utterance: DocumentUtterance) -> String {
        "\(timestamp(utterance.startTime)) – \(timestamp(utterance.endTime))"
    }
}
