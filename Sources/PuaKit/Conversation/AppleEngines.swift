import AVFoundation
import CoreMedia
import Foundation
import FoundationModels
import Speech

/// On-device speech recognition (macOS 26 SpeechTranscriber). Downloads the locale's model on
/// first use.
public final class AppleSpeechRecognizer: SpeechRecognizer, @unchecked Sendable {
    public let name = "apple"
    public let results: AsyncStream<RecognizedSpeech>
    private let resultsContinuation: AsyncStream<RecognizedSpeech>.Continuation
    private let locale: Locale
    private var analyzer: SpeechAnalyzer?
    private var converter: AVAudioConverter?
    private var inFormat: AVAudioFormat?
    private var outFormat: AVAudioFormat?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var tasks: [Task<Void, Never>] = []
    private var finished = false

    public init(locale: Locale) {
        self.locale = locale
        (results, resultsContinuation) = AsyncStream<RecognizedSpeech>.makeStream()
    }

    public func prepare() async throws {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            Events.shared.emit("installing_speech_assets", ["locale": locale.identifier])
            try await request.downloadAndInstall()
        }
        guard let sttFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
              let callFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: callFormat, to: sttFormat) else {
            throw PuaError("stt_format", "no audio format for SpeechAnalyzer")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: sttFormat)
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        self.analyzer = analyzer
        self.converter = converter
        self.inFormat = callFormat
        self.outFormat = sttFormat
        self.input = input
        let out = resultsContinuation
        tasks.append(Task { _ = try? await analyzer.analyzeSequence(stream) })
        tasks.append(Task {
            do {
                for try await r in transcriber.results {
                    let text = String(r.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    out.yield(RecognizedSpeech(text: text, isFinal: r.isFinal, end: r.range.end.seconds))
                }
            } catch is CancellationError {
            } catch {
                Events.shared.emit("stt_error", ["error": "\(error)"])
            }
            out.finish()
        })
    }

    public func append(_ samples: UnsafeBufferPointer<Float>) {
        guard let converter, let inFormat, let outFormat, let input, let base = samples.baseAddress,
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat,
                                            frameCapacity: AVAudioFrameCount(Double(samples.count) * outFormat.sampleRate / 48_000) + 32)
        else { return }
        inBuf.floatChannelData![0].update(from: base, count: samples.count)
        inBuf.frameLength = AVAudioFrameCount(samples.count)
        var given = false
        var error: NSError?
        converter.convert(to: outBuf, error: &error) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return inBuf
        }
        if outBuf.frameLength > 0 { input.yield(AnalyzerInput(buffer: outBuf)) }
    }

    public func finish() async {
        guard !finished else { return }
        finished = true
        input?.finish()
        await analyzer?.cancelAndFinishNow()
        tasks.forEach { $0.cancel() }
        resultsContinuation.finish()
    }
}

/// Apple's on-device Foundation Models (Apple Intelligence). Starts a new session when the
/// context window fills up.
public final class AppleReplyModel: ReplyModel, @unchecked Sendable {
    public let name = "apple"
    private let instructions: String
    private var session: LanguageModelSession

    public init(instructions: String) {
        self.instructions = instructions
        session = LanguageModelSession(instructions: instructions)
    }

    public func prepare() async throws {
        guard case .available = SystemLanguageModel.default.availability else {
            throw PuaError("llm_unavailable", "Apple Intelligence model unavailable: \(SystemLanguageModel.default.availability)")
        }
        session.prewarm()
    }

    public func reply(to callerText: String) -> AsyncThrowingStream<String, Error> {
        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = Task {
                // Snapshots of a plain-text response only grow; pass on what is new in each.
                var previous = ""
                do {
                    for try await snapshot in session.streamResponse(to: callerText) {
                        let full = snapshot.content
                        if full.count > previous.count, full.hasPrefix(previous) {
                            continuation.yield(String(full.dropFirst(previous.count)))
                            previous = full
                        }
                    }
                    continuation.finish()
                } catch {
                    if case LanguageModelSession.GenerationError.exceededContextWindowSize = error {
                        self.session = LanguageModelSession(instructions: self.instructions)
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
