/* ============================================================
   MyADHD/Voice/WAV.swift — the bytes, and the two rules about samples

   `toWav`, `resample` and `heardAnything` from voice.js (240-262,
   222-234, 278-285), which are the three things in that file that are
   arithmetic rather than browser.

   **Why they are here and not in `VoiceRecorder`.** Nothing in this file
   imports AVFoundation, and that is deliberate: `Checks/wav.sh` compiles
   it on its own with `swiftc` for macOS, where `AVAudioSession` does not
   exist, and holds its output against voice.js's own writer running in
   JavaScriptCore. A writer that could only be built for the phone would
   be a writer nobody could check.

   The endpoint takes wav, mp3, aiff, aac, ogg or flac. `AVAudioFile`
   would happily write a .caf or an .m4a and neither is on that list, so
   the 44-byte header is written by hand here exactly as the web writes
   it — same field order, same little-endian, same rounding of a float
   sample onto a 16-bit integer.

   **The float-to-int16 rule is the fiddly one.** JavaScript's
   `DataView.setInt16` runs ToInteger on its argument: truncate toward
   zero, then take it modulo 2^16. The asymmetric scale — 0x8000 going
   down and 0x7fff coming up — means the product never leaves
   [-32768, 32767], so nothing ever wraps and the modulo never shows.
   NaN is the one input that does not simply scale: ToInteger gives 0,
   so a NaN sample is written as silence rather than trapping the way an
   `Int16(_:)` conversion would.

   The arithmetic is done in `Double` throughout, not `Float`, because
   that is what JavaScript does with a Float32Array element the moment it
   is read out of one. `Float(sum / count)` at the end of `resample` is
   the store back into a Float32Array, and it rounds in the same place.
   ============================================================ */

import Foundation

// MARK: -

enum WAV {

    /// 44 bytes: RIFF, a 16-byte PCM `fmt ` chunk, and `data`.
    static let headerBytes = 44

    /// `toWav(pcm, rate)` (voice.js:240-262). 16-bit, mono, little-endian,
    /// at whatever rate it is handed — which in this app is always
    /// `VoiceRecorder.rate`, because the resample above it has already
    /// happened.
    static func encode(_ pcm: [Float], rate: Int) -> Data {
        var out = Data(capacity: headerBytes + pcm.count * 2)
        let dataBytes = UInt32(pcm.count * 2)

        out.append(tag("RIFF"))
        out.append(le32(36 + dataBytes))
        out.append(tag("WAVE"))

        out.append(tag("fmt "))
        out.append(le32(16))                      // chunk size
        out.append(le16(1))                       // PCM
        out.append(le16(1))                       // mono
        out.append(le32(UInt32(rate)))
        out.append(le32(UInt32(rate * 2)))        // bytes per second
        out.append(le16(2))                       // block align
        out.append(le16(16))                      // bits

        out.append(tag("data"))
        out.append(le32(dataBytes))

        for sample in pcm {
            let word = int16(sample)
            out.append(UInt8(truncatingIfNeeded: word))
            out.append(UInt8(truncatingIfNeeded: word >> 8))
        }
        return out
    }

    /// `const s = Math.max(-1, Math.min(1, pcm[i]));`
    /// `v.setInt16(o, s < 0 ? s * 0x8000 : s * 0x7fff, true);`
    static func int16(_ sample: Float) -> Int16 {
        let x = Double(sample)
        /* `Math.min(1, NaN)` is NaN and so is `Math.max(-1, NaN)`; Swift's
           own min/max disagree about which operand a NaN comparison
           returns, so NaN is carried through by hand. */
        let clamped = x.isNaN ? Double.nan : Swift.max(-1, Swift.min(1, x))
        let scaled = clamped < 0 ? clamped * 32768 : clamped * 32767
        guard !scaled.isNaN else { return 0 }     // ToInteger(NaN) === 0
        return Int16(truncatingIfNeeded: Int(scaled))
    }

    // MARK: - the sample rules voice.js keeps beside the writer

    /// `resample(input, from, to)` (voice.js:222-234).
    ///
    /// Box averaging, not point sampling. Dropping two of every three
    /// samples folds everything above 8 kHz back down into the speech
    /// band as hiss, and hiss is exactly what a transcriber does not
    /// need.
    static func resample(_ input: [Float], from: Double, to: Double) -> [Float] {
        if from == to { return input }
        let ratio = from / to
        let count = Int((Double(input.count) / ratio).rounded(.down))
        guard count > 0 else { return [] }

        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let start = Int((Double(i) * ratio).rounded(.down))
            let end = Swift.min(Int((Double(i + 1) * ratio).rounded(.down)), input.count)
            var sum = 0.0
            var j = start
            while j < end {
                sum += Double(input[j])
                j += 1
            }
            out[i] = Float(sum / Double(Swift.max(1, end - start)))
        }
        return out
    }

    /// `heardAnything(pcm)` (voice.js:278-285). The floor under which a
    /// recording is never uploaded: a tapped button, or a hold in a
    /// pocket. Anything genuinely quiet but real still clears it — it is
    /// a floor, not a gate.
    ///
    /// The peak is compared as a `Double` because that is the comparison
    /// JavaScript makes. `0.01` as a `Float` is 0.00999999977648, just
    /// under the literal, and a sample landing in that gap would be
    /// uploaded here and dropped by the web.
    static let silenceFloor = 0.01

    static func heardAnything(_ pcm: [Float]) -> Bool {
        var peak = 0.0
        for sample in pcm {
            let a = abs(Double(sample))
            if a > peak { peak = a }
        }
        return peak > silenceFloor
    }

    // MARK: - little-endian, by hand

    private static func tag(_ s: String) -> Data { Data(s.utf8) }

    private static func le16(_ v: UInt16) -> Data {
        Data([UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)])
    }

    private static func le32(_ v: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: v),
              UInt8(truncatingIfNeeded: v >> 8),
              UInt8(truncatingIfNeeded: v >> 16),
              UInt8(truncatingIfNeeded: v >> 24)])
    }
}
