import Foundation

public extension ImageRecognitionResult {
    /// Rejoin visual line wraps while retaining paragraph gaps, short lines and columns.
    /// This is a geometry heuristic; individual lines remain available in separate mode.
    var flowingText: String {
        let visible = lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let first = visible.first else { return "" }
        var output = first.text
        for (previous, next) in zip(visible, visible.dropFirst()) {
            let height = max(0.00001, max(previous.bounds.height, next.bounds.height))
            let gap = next.bounds.minY - previous.bounds.maxY
            let leftAligned = abs(previous.bounds.minX - next.bounds.minX) <= height * 1.5
            let similarHeight = min(previous.bounds.height, next.bounds.height) / height >= 0.65
            let verticalProgress = next.bounds.midY > previous.bounds.midY + height * 0.4
            let shortLine = previous.bounds.width < next.bounds.width * 0.68
            let listLine = next.text.range(of: #"^\s*(?:[•●▪\-–]|\d+[.)、])\s*"#, options: .regularExpression) != nil
            let paragraph = !leftAligned || !similarHeight || !verticalProgress || gap > height * 1.05 || shortLine || listLine
            if paragraph {
                output += (gap > height * 1.05 && verticalProgress ? "\n\n" : "\n") + next.text
            } else if output.last == "-", let lastWord = previous.text.dropLast().last, lastWord.isASCII,
                      lastWord.isLetter, let start = next.text.first, start.isASCII, start.isLowercase {
                output.removeLast(); output += next.text
            } else {
                let end = output.last, start = next.text.first
                let noSpace = end.map(Self.isCJK) == true || start.map(Self.isCJK) == true ||
                    start.map { "，。！？；：、）】》”’.,!?;:)]}".contains($0) } == true ||
                    end?.isWhitespace == true || start?.isWhitespace == true
                output += (noSpace ? "" : " ") + next.text
            }
        }
        return output
    }
    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            (0x2E80...0x9FFF).contains(scalar.value) || (0xF900...0xFAFF).contains(scalar.value) ||
            (0x20000...0x323AF).contains(scalar.value) || (0xFF00...0xFFEF).contains(scalar.value)
        }
    }
}
