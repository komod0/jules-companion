import Foundation
import Speech
import AVFoundation
import Combine
import AppKit

/// Delegate protocol for speech transcription events
/// Designed for reusability - can be integrated into any component
@MainActor
protocol SpeechTranscriptionDelegate: AnyObject {
    /// Called when transcription text is updated (live updates during speech)
    func speechTranscriptionDidUpdate(text: String, isFinal: Bool)
    /// Called when speech has ended (silence detected)
    func speechTranscriptionDidDetectSpeechEnd()
    /// Called when an error occurs
    func speechTranscriptionDidFail(error: SpeechTranscriptionError)
    /// Called when recording state changes
    func speechTranscriptionDidChangeState(isRecording: Bool)
}

/// Errors that can occur during speech transcription
enum SpeechTranscriptionError: Error, LocalizedError {
    case microphonePermissionDenied
    case speechRecognitionPermissionDenied
    case audioSessionSetupFailed(Error)
    case recognitionFailed(Error)
    case notAvailable
    case alreadyRecording
    case modelNotAvailable
    case modelDownloadFailed(Error)
    case audioEngineFailure(Error)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone access is required for voice input. Please enable it in System Settings > Privacy & Security > Microphone."
        case .speechRecognitionPermissionDenied:
            return "Speech recognition access is required. Please enable it in System Settings > Privacy & Security > Speech Recognition."
        case .audioSessionSetupFailed(let error):
            return "Failed to set up audio: \(error.localizedDescription)"
        case .recognitionFailed(let error):
            return "Speech recognition failed: \(error.localizedDescription)"
        case .notAvailable:
            return "Speech recognition is not available on this device."
        case .alreadyRecording:
            return "Already recording. Please stop the current recording first."
        case .modelNotAvailable:
            return "Speech recognition model is not available. Please ensure the model is downloaded."
        case .modelDownloadFailed(let error):
            return "Failed to download speech recognition model: \(error.localizedDescription)"
        case .audioEngineFailure(let error):
            return "Audio system error: \(error.localizedDescription). Try closing other audio apps or restarting your Mac."
        }
    }
}

/// Manages speech-to-text transcription using macOS 26 SpeechAnalyzer framework
/// Uses SpeechTranscriber for transcription and SpeechDetector for voice activity detection
@available(macOS 26.0, *)
@MainActor
final class SpeechTranscriptionManager: ObservableObject {

    // MARK: - Singleton

    static let shared = SpeechTranscriptionManager()

    // MARK: - Published Properties

    /// The current transcription text (accumulated across recording sessions)
    @Published private(set) var transcribedText: String = ""

    /// Text accumulated from previous recording sessions (prepended to new transcription)
    private var accumulatedText: String = ""

    /// Whether recording is currently active
    @Published private(set) var isRecording: Bool = false

    /// Whether speech recognition is available
    @Published private(set) var isAvailable: Bool = false

    /// Whether we have all necessary permissions
    @Published private(set) var hasPermissions: Bool = false

    /// Current error, if any
    @Published private(set) var currentError: SpeechTranscriptionError?

    // MARK: - Publishers

    /// Publisher for when speech ends (silence detected)
    let speechEndedPublisher = PassthroughSubject<Void, Never>()

    /// Publisher for transcription updates
    let transcriptionPublisher = PassthroughSubject<(text: String, isFinal: Bool), Never>()

    // MARK: - Delegate

    weak var delegate: SpeechTranscriptionDelegate?

    // MARK: - Private Properties

    private var speechTranscriber: SpeechTranscriber?
    private var speechDetector: SpeechDetector?
    private var speechAnalyzer: SpeechAnalyzer?
    private var analyzerFormat: AVAudioFormat?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?

    /// Audio engine - recreated for each recording session to avoid HALC state issues
    private var audioEngine: AVAudioEngine?
    private var audioConverter: AVAudioConverter?
    /// Tracks whether we have an active tap installed on the audio input node
    private var hasTapInstalled: Bool = false

    private var transcriptionTask: Task<Void, Never>?
    private var detectorTask: Task<Void, Never>?

    // MARK: - Initialization

    private init() {
        Task { @MainActor in
            await checkAvailability()
        }
    }

    // MARK: - Availability Check

    private func checkAvailability() async {
        // Check if SpeechTranscriber supports current locale
        let supportedLocales = await SpeechTranscriber.supportedLocales
        let currentLocale = Locale(identifier: "en-US")
        isAvailable = supportedLocales.contains(currentLocale)
    }

    // MARK: - Permission Management

    /// Request all necessary permissions for speech transcription
    func requestPermissions() async -> Bool {
        // Request microphone permission
        let microphoneGranted = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }

        guard microphoneGranted else {
            currentError = .microphonePermissionDenied
            hasPermissions = false
            return false
        }

        // Request speech recognition permission
        let speechGranted = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }

        guard speechGranted else {
            currentError = .speechRecognitionPermissionDenied
            hasPermissions = false
            return false
        }

        hasPermissions = true
        currentError = nil
        return true
    }

    /// Check current permission status without requesting
    func checkPermissionStatus() -> (microphone: Bool, speechRecognition: Bool) {
        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let speechStatus = SFSpeechRecognizer.authorizationStatus() == .authorized
        hasPermissions = microphoneStatus && speechStatus
        return (microphoneStatus, speechStatus)
    }

    /// Open System Settings to the appropriate privacy section
    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Model Management

    /// Ensure the speech recognition model is downloaded and installed for the given transcriber
    /// This must be called before starting the analyzer to avoid "unallocated locales" errors
    private func downloadModelIfNeeded(for transcriber: SpeechTranscriber) async throws {
        if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await downloader.downloadAndInstall()
        }
    }

    // MARK: - Recording Control

    /// Start recording and transcribing speech using SpeechTranscriber
    func startRecording() async throws {
        // Force reset any stale state before starting
        if isRecording {
            throw SpeechTranscriptionError.alreadyRecording
        }

        // Clean up any leftover state from previous sessions
        cleanupAudioResources()

        // Ensure we have permissions
        let granted = await requestPermissions()
        guard granted else {
            throw currentError ?? .microphonePermissionDenied
        }

        // Save current transcription to accumulated text (add space separator if both have content)
        if !transcribedText.isEmpty {
            if !accumulatedText.isEmpty {
                accumulatedText += " " + transcribedText
            } else {
                accumulatedText = transcribedText
            }
        }

        // Reset current session state (but keep accumulated text)
        currentError = nil

        // Create SpeechTranscriber for transcription
        let locale = Locale(identifier: "en-US")
        speechTranscriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )

        guard let transcriber = speechTranscriber else {
            throw SpeechTranscriptionError.notAvailable
        }

        // Ensure the speech recognition model is downloaded and installed
        // This must be called before starting the analyzer to avoid "unallocated locales" errors
        do {
            try await downloadModelIfNeeded(for: transcriber)
        } catch {
            cleanupAudioResources()
            throw SpeechTranscriptionError.modelDownloadFailed(error)
        }

        // Create SpeechDetector for voice activity detection
        speechDetector = SpeechDetector()

        // Create SpeechAnalyzer with modules
        // Note: SpeechDetector conformance to SpeechModule may require macOS 26.1+
        var modules: [any SpeechModule] = [transcriber]
        if let detector = speechDetector {
            modules.append(detector)
        }
        speechAnalyzer = SpeechAnalyzer(modules: modules)

        guard let analyzer = speechAnalyzer else {
            cleanupAudioResources()
            throw SpeechTranscriptionError.notAvailable
        }

        // Get best audio format for the modules
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules)

        guard let targetFormat = analyzerFormat else {
            cleanupAudioResources()
            throw SpeechTranscriptionError.notAvailable
        }

        // Create async stream for audio input
        let (inputStream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = continuation

        // Create fresh audio engine for this session to avoid HALC state issues
        let engine = AVAudioEngine()
        self.audioEngine = engine

        // Brief delay to let HAL (Hardware Abstraction Layer) initialize
        try? await Task.sleep(for: .milliseconds(50))

        // Set up audio converter if needed
        // Retry getting audio format with delays to handle hardware initialization
        let inputNode = engine.inputNode
        let inputFormat = try await getValidAudioFormat(from: inputNode, engine: engine)

        if inputFormat != targetFormat {
            audioConverter = AVAudioConverter(from: inputFormat, to: targetFormat)
        }

        // Install tap to capture audio and feed to analyzer
        // Use smaller buffer (512 samples ≈ 10ms at 48kHz) for lower latency word-by-word updates
        do {
            inputNode.installTap(onBus: 0, bufferSize: 512, format: inputFormat) { [weak self] buffer, _ in
                guard let self = self else { return }
                Task { @MainActor in
                    self.processAudioBuffer(buffer)
                }
            }
            hasTapInstalled = true
        } catch {
            cleanupAudioResources()
            throw SpeechTranscriptionError.audioEngineFailure(error)
        }

        // Start audio engine
        do {
            engine.prepare()
            try engine.start()
        } catch {
            cleanupAudioResources()
            throw SpeechTranscriptionError.audioEngineFailure(error)
        }

        isRecording = true
        delegate?.speechTranscriptionDidChangeState(isRecording: true)

        // Start transcription results task
        transcriptionTask = Task { @MainActor in
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled else { break }

                    let newText = String(result.text.characters)
                    // Combine accumulated text with new transcription
                    if !self.accumulatedText.isEmpty && !newText.isEmpty {
                        self.transcribedText = self.accumulatedText + " " + newText
                    } else if !self.accumulatedText.isEmpty {
                        self.transcribedText = self.accumulatedText
                    } else {
                        self.transcribedText = newText
                    }

                    let isFinal = result.isFinal
                    self.transcriptionPublisher.send((text: self.transcribedText, isFinal: isFinal))
                    self.delegate?.speechTranscriptionDidUpdate(text: self.transcribedText, isFinal: isFinal)
                }
            } catch {
                if !Task.isCancelled {
                    self.currentError = .recognitionFailed(error)
                    self.delegate?.speechTranscriptionDidFail(error: .recognitionFailed(error))
                }
            }
        }

        // Start speech detector results task
        if let detector = speechDetector {
            detectorTask = Task { @MainActor in
                do {
                    for try await result in detector.results {
                        guard !Task.isCancelled else { break }

                        // SpeechDetector provides voice activity segments
                        // When we detect end of speech segment, notify delegate
                        if result.isFinal && !self.transcribedText.isEmpty {
                            self.speechEndedPublisher.send()
                            self.delegate?.speechTranscriptionDidDetectSpeechEnd()
                        }
                    }
                } catch {
                    // Speech detector errors are non-fatal
                }
            }
        }

        // Start the analyzer with input stream
        do {
            try await analyzer.start(inputSequence: inputStream)
        } catch {
            stopRecording()
            throw SpeechTranscriptionError.recognitionFailed(error)
        }
    }

    /// Get a valid audio format from the input node, with retries for hardware initialization
    private func getValidAudioFormat(from inputNode: AVAudioInputNode, engine: AVAudioEngine) async throws -> AVAudioFormat {
        var lastError: Error?

        for attempt in 1...3 {
            // Getting inputNode.outputFormat can throw if audio hardware is in a bad state
            let format = inputNode.outputFormat(forBus: 0)
            if format.sampleRate > 0 {
                return format
            }
            lastError = NSError(domain: NSOSStatusErrorDomain, code: -10877,
                               userInfo: [NSLocalizedDescriptionKey: "Invalid audio format - sample rate is 0"])
            if attempt < 3 {
                // Wait for audio hardware to initialize (50ms, 100ms delays)
                try? await Task.sleep(for: .milliseconds(50 * attempt))
            }
        }

        cleanupAudioResources()
        throw SpeechTranscriptionError.audioEngineFailure(lastError!)
    }

    /// Process audio buffer and feed to SpeechAnalyzer
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let continuation = inputContinuation,
              let targetFormat = analyzerFormat else { return }

        let outputBuffer: AVAudioPCMBuffer

        if let converter = audioConverter {
            // Convert to target format
            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: AVAudioFrameCount(targetFormat.sampleRate * Double(buffer.frameLength) / buffer.format.sampleRate)
            ) else { return }

            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if error != nil { return }
            outputBuffer = convertedBuffer
        } else {
            outputBuffer = buffer
        }

        // Feed to analyzer
        continuation.yield(AnalyzerInput(buffer: outputBuffer))
    }

    /// Stop recording
    func stopRecording() {
        guard isRecording else { return }

        cleanupAudioResources()

        isRecording = false
        delegate?.speechTranscriptionDidChangeState(isRecording: false)
    }

    /// Force reset all state - use this when the audio system is in a bad state
    /// This will stop any ongoing recording and clean up all resources
    func forceReset() {
        cleanupAudioResources()

        isRecording = false
        transcribedText = ""
        accumulatedText = ""
        currentError = nil
        delegate?.speechTranscriptionDidChangeState(isRecording: false)
    }

    /// Clean up all audio resources without checking isRecording state
    /// This ensures proper cleanup even when errors occur before isRecording is set
    private func cleanupAudioResources() {
        // Cancel tasks
        transcriptionTask?.cancel()
        transcriptionTask = nil
        detectorTask?.cancel()
        detectorTask = nil

        // Stop audio engine and remove tap
        if let engine = audioEngine {
            engine.stop()
            if hasTapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                hasTapInstalled = false
            }
        }
        audioEngine = nil

        // Finish input stream (this signals the analyzer to stop)
        inputContinuation?.finish()
        inputContinuation = nil

        // Clean up
        speechAnalyzer = nil
        speechTranscriber = nil
        speechDetector = nil
        audioConverter = nil
        analyzerFormat = nil
    }

    /// Clear the current transcription (including accumulated text)
    func clearTranscription() {
        transcribedText = ""
        accumulatedText = ""
    }

    /// Set transcription text directly (for editing)
    func setTranscription(_ text: String) {
        transcribedText = text
        // When setting text directly, replace accumulated text too
        accumulatedText = ""
    }
}
