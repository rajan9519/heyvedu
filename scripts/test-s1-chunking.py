#!/usr/bin/env python3
"""Exercise the production sentence chunker without downloading models or launching the app."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
source = (root / 'HeyVedu/Pipeline/TextCleaner.swift').read_text()
chunker = source.split('nonisolated enum SentenceChunker {', 1)[1].split(
    '/// Deterministic touch-ups', 1)[0]
program = '''import Foundation
import NaturalLanguage
nonisolated enum DebugTrace { static func write(_ message: String) {} }
nonisolated enum SentenceChunker {''' + chunker + r'''
@main struct ChunkingChecks {
    static func main() async {
        let cases = [
            "",
            "um",
            "Send the report. Call Sarah. Book the room.",
            String(repeating: "unpunctuated speech with fillers um ", count: 150),
            String(repeating: "x", count: 300),
            String(repeating: "hello 👋🏽 café 中文 ", count: 100),
            "  First sentence.\n\nSecond sentence.  ",
        ]
        for text in cases {
            let chunks = await SentenceChunker.chunks(of: text, budget: 80) { $0.utf8.count }
            precondition(chunks.allSatisfy { $0.utf8.count <= 80 }, "Oversized chunk")
            precondition(chunks.joined().filter { !$0.isWhitespace } == text.filter { !$0.isWhitespace },
                         "Lost or duplicated transcript content")
        }
        let sentences = await SentenceChunker.chunks(of: "Hello there. Goodbye now.", budget: 14) { $0.count }
        precondition(sentences == ["Hello there.", "Goodbye now."], "Split a fitting sentence")
        let short = "  Keep this short input unchanged.  "
        let unchanged = await SentenceChunker.chunks(of: short, budget: 800) { $0.count }
        precondition(unchanged == [short])
        let text = "Hello there. Goodbye now."
        let measured = await SentenceChunker.chunks(of: text, budget: 25) {
            $0.count + ($0.contains(". ") ? 10 : 0)
        }
        precondition(measured == ["Hello there.", "Goodbye now."], "Didn't measure combined token count")
        print("Passed 10 chunking checks (sentences, unpunctuated speech, unbroken words, Unicode, empty input, exact combined counts).")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='heyvedu-s1-tests-') as directory:
    directory = Path(directory)
    swift = directory / 'ChunkingChecks.swift'
    swift.write_text(program)
    binary = directory / 'checks'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path',
                    str(directory / 'cache'), str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
