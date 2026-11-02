import AVFoundation
import Foundation
import os

struct RecordingResult {
    let url: URL
    let duration: Double
    /// Loudest RMS level seen, in dBFS. Used to skip sending silence.
    let peakDecibels: Float
}

enum RecorderError: LocalizedError {
    case noInputDevice
    case cannotCreateFile(String)
    case engineStart(String)

    var errorDescription: String? {
        switch self {
        case .noInputDevice: return "No microphone is available."
        case .cannotCreateFile(let m): return "Could not create the recording file: \(m)"
        case .engineStart(let m): return "Could not start the microphone: \(m)"
        }
    }
}

/// Records the default input device to a mono 24 kHz AAC `.m4a` (a documented upload format,
/// ~0.5 MB per minute, so the 30-minute cap stays far below the 25 MB limit).
///
/// If the input device changes mid-recording (headset unplugged, AirPods switching profile),
/// the engine is rebuilt on the new default device and keeps appending to the same file.
/// Only when no input device is left does it report `onInterrupted`.
final class AudioRecorder {
    static let sampleRate: Double = 24_000
    private let log = Logger(subsystem: "local.dictate", category: "audio")

    /// Normalized 0…1 input level, delivered on the main queue.
    var onLevel: ((Float) -> Void)?
    /// No usable input device remains; the caller should stop and keep what was captured.
    var onInterrupted: (() -> Void)?
    /// Recording continued on a different input device.
    var onDeviceSwitched: (() -> Void)?

    private var engine: AVAudioEngine?
    private var file: AVAudioFile?
    private var url: URL?
    private let writeQueue = DispatchQueue(label: "local.dictate.audio-write")
    private let stateLock = NSLock()
    private var framesWritten: AVAudioFramePosition = 0
    private var peakDecibels: Float = -160
    private var configObserver: NSObjectProtocol?

    private static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                                    channels: 1, interleaved: false)!

    var isRecording: Bool { file != nil }

    func start(to url: URL) throws {
        stop(discard: true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw RecorderError.cannotCreateFile(error.localizedDescription)
        }
        stateLock.withLock { framesWritten = 0; peakDecibels = -160 }
        self.file = file
        self.url = url
        do {
            try startEngine()
        } catch {
            self.file = nil
            self.url = nil
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private func startEngine() throws {
        // A fresh engine picks up the current default input device.
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw RecorderError.noInputDevice }
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat) else {
            throw RecorderError.engineStart("unsupported input format")
        }
        converter.downmix = true

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer, converter: converter)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecorderError.engineStart(error.localizedDescription)
        }
        self.engine = engine
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    private func teardownEngine() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    private func handleConfigurationChange() {
        guard file != nil else { return }
        log.notice("Audio input configuration changed during recording")
        teardownEngine()
        do {
            try startEngine()
            onDeviceSwitched?()
        } catch {
            onInterrupted?()
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
        let db = Self.rmsDecibels(buffer)
        let level = max(0, min(1, (db + 55) / 50))
        stateLock.withLock { peakDecibels = max(peakDecibels, db) }
        DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }

        let ratio = Self.targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else { return }
        writeQueue.async { [weak self] in
            guard let self, let file = self.file else { return }
            do {
                try file.write(from: out)
                self.stateLock.withLock { self.framesWritten += AVAudioFramePosition(out.frameLength) }
            } catch {
                self.log.error("Audio write failed")
            }
        }
    }

    private static func rmsDecibels(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return -160 }
        let frames = Int(buffer.frameLength)
        var sum: Float = 0
        let samples = data[0]
        for i in 0..<frames { sum += samples[i] * samples[i] }
        let rms = (sum / Float(frames)).squareRoot()
        return rms > 0 ? 20 * log10(rms) : -160
    }

    /// Stops and finalizes the file. With `discard`, the file is deleted and nil returned.
    @discardableResult
    func stop(discard: Bool = false) -> RecordingResult? {
        teardownEngine()
        guard file != nil, let url else { return nil }
        // Drain pending writes, then release the file so the AAC container is finalized.
        writeQueue.sync { self.file = nil }
        self.url = nil
        let (frames, peak) = stateLock.withLock { (framesWritten, peakDecibels) }
        if discard {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return RecordingResult(url: url, duration: Double(frames) / Self.sampleRate, peakDecibels: peak)
    }
}
