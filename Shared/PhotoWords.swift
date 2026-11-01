/* ============================================================
   Shared/PhotoWords.swift — the words in a photo, read on the phone

   One reader for both ways a photo becomes a dump: the share sheet
   (DumpShare/ShareViewController.swift) and the photo button in the
   app's own composer (MyADHD/UI/Composer.swift). Compiled into both
   targets, so the two can never read the same poster differently.

   Nothing leaves the device: Vision does the reading, and the photo is
   not kept. Each photo comes back as ONE line, its lines joined with
   commas, because the sorter reads a line as a thought, and a poster
   read as five lines would come back as five tasks.
   ============================================================ */

import ImageIO
import UIKit
import Vision

enum PhotoWords {

    /// The most photos read in one go. Four decoded photos with four text
    /// readers is already as much as a share extension may hold.
    static let most = 4

    /// The words of one photo, or "" when there are none. Slow: call it
    /// off the main thread, and one photo at a time.
    static func read(_ value: Any?) -> String {
        autoreleasepool {
            guard let image = image(from: value) else { return "" }
            return words(in: image)
        }
    }

    /// The photo, shrunk on the way in: a 48MP photo decoded whole would
    /// not survive a share extension's memory limit, and 2400 pixels on
    /// the long side is plenty to read a poster.
    static func image(from value: Any?) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2400,
        ]
        let source: CGImageSource?
        switch value {
        case let url as URL:   source = CGImageSourceCreateWithURL(url as CFURL, nil)
        case let data as Data: source = CGImageSourceCreateWithData(data as CFData, nil)
        case let image as UIImage: return image.cgImage
        default: return nil
        }
        guard let source else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The words, top to bottom, as one line. Language correction is off:
    /// it "fixes" Malay into English, and a kenduri is not a kendo.
    static func words(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let lines = (request.results ?? []).compactMap {
            $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces)
        }
        return lines.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// Found words after what was already in the box, on a line of their
    /// own: never over the person's words.
    static func append(_ found: String, to typed: String) -> String {
        let kept = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return kept.isEmpty ? found : kept + "\n" + found
    }
}
