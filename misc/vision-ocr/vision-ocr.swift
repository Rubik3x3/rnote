// Tiny macOS helper for the "Quick Text" button of rnote's Transcription tab.
// Reads a PNG path, runs Apple's on-device handwriting recognition (Vision framework, offline,
// no LLM) and prints the recognized lines top to bottom. Built and installed by meson on macOS.
import AppKit
import Foundation
import Vision

guard CommandLine.arguments.count == 2,
    let image = NSImage(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])),
    let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    FileHandle.standardError.write("usage: rnote-vision-ocr <image.png>\n".data(using: .utf8)!)
    exit(2)
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.recognitionLanguages = ["es-ES", "en-US"]
request.usesLanguageCorrection = true
do {
    try VNImageRequestHandler(cgImage: cgImage).perform([request])
} catch {
    FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
    exit(1)
}

// Vision's origin is bottom-left: sort by descending y for reading order, then by x.
let lines = (request.results ?? [])
    .sorted {
        abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.01
            ? $0.boundingBox.midY > $1.boundingBox.midY
            : $0.boundingBox.minX < $1.boundingBox.minX
    }
    .compactMap { $0.topCandidates(1).first?.string }
print(lines.joined(separator: "\n"))
