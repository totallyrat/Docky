// Synthesizes Docky's bundled alert tones as 16-bit mono WAV files.
// Usage: swift SoundGen.swift <output-dir>
import Foundation

let sampleRate = 44_100.0

func writeWAV(_ samples: [Double], to url: URL) throws {
    var data = Data()
    func append<T: FixedWidthInteger>(_ v: T) { var le = v.littleEndian; data.append(Data(bytes: &le, count: MemoryLayout<T>.size)) }
    let pcm = samples.map { Int16(max(-1, min(1, $0)) * Double(Int16.max)) }
    let byteCount = UInt32(pcm.count * 2)
    data.append("RIFF".data(using: .ascii)!); append(UInt32(36) + byteCount)
    data.append("WAVE".data(using: .ascii)!)
    data.append("fmt ".data(using: .ascii)!); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
    append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
    data.append("data".data(using: .ascii)!); append(byteCount)
    pcm.forEach { append($0) }
    try data.write(to: url)
}

func silence(_ seconds: Double) -> [Double] { Array(repeating: 0, count: Int(seconds * sampleRate)) }

/// Soft-edged sine burst with a couple of harmonics.
func beep(freq: Double, duration: Double, gain: Double = 0.5) -> [Double] {
    let n = Int(duration * sampleRate)
    let attack = 0.006, release = 0.03
    return (0..<n).map { i in
        let t = Double(i) / sampleRate
        let env = min(1, t / attack) * min(1, (duration - t) / release)
        let s = sin(2 * .pi * freq * t) + 0.25 * sin(2 * .pi * freq * 2 * t) + 0.08 * sin(2 * .pi * freq * 3 * t)
        return s * env * gain / 1.33
    }
}

/// Bell-like strike with inharmonic partials and exponential decay.
func bell(freq: Double, duration: Double, gain: Double = 0.45) -> [Double] {
    let n = Int(duration * sampleRate)
    let partials: [(ratio: Double, amp: Double, decay: Double)] = [(1, 1, 2.2), (2.0, 0.35, 3.5), (2.76, 0.22, 5), (5.4, 0.08, 9)]
    return (0..<n).map { i in
        let t = Double(i) / sampleRate
        let attack = min(1, t / 0.003)
        var s = 0.0
        for p in partials { s += p.amp * exp(-p.decay * t) * sin(2 * .pi * freq * p.ratio * t) }
        return s * attack * gain / 1.65
    }
}

func mix(_ base: inout [Double], _ add: [Double], at seconds: Double) {
    let offset = Int(seconds * sampleRate)
    if base.count < offset + add.count { base += Array(repeating: 0, count: offset + add.count - base.count) }
    for (i, v) in add.enumerated() { base[offset + i] += v }
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

// Radar: two bursts of four quick rising pips.
var radar = silence(1.6)
for group in 0..<2 {
    let start = Double(group) * 0.55
    for (i, f) in [1568.0, 1760, 1976, 2093].enumerated() {
        mix(&radar, beep(freq: f, duration: 0.075, gain: 0.42), at: start + Double(i) * 0.105)
    }
}
try writeWAV(radar, to: out.appendingPathComponent("Radar.wav"))

// Chime: a gentle major arpeggio.
var chime = silence(2.2)
for (i, f) in [1046.5, 1318.5, 1568.0, 2093.0].enumerated() {
    mix(&chime, bell(freq: f, duration: 1.8, gain: 0.32), at: Double(i) * 0.14)
}
try writeWAV(chime, to: out.appendingPathComponent("Chime.wav"))
print("sounds written to \(out.path)")
