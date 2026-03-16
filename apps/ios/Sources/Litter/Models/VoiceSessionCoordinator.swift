import AVFoundation
import Foundation

@MainActor
final class VoiceSessionCoordinator {
    enum Event {
        case inputLevel(Float)
        case outputLevel(Float)
        case routeChanged(VoiceSessionAudioRoute)
        case interrupted
        case failure(String)
    }

    private actor AudioUploadPump {
        private let send: @Sendable (ThreadRealtimeAudioChunk) async -> Void
        private var queue: [ThreadRealtimeAudioChunk] = []
        private var draining = false

        init(send: @escaping @Sendable (ThreadRealtimeAudioChunk) async -> Void) {
            self.send = send
        }

        func enqueue(_ chunk: ThreadRealtimeAudioChunk) async {
            queue.append(chunk)
            guard !draining else { return }
            draining = true
            while !queue.isEmpty {
                let next = queue.removeFirst()
                await send(next)
            }
            draining = false
        }
    }

    var onEvent: ((Event) -> Void)?

    private let session = AVAudioSession.sharedInstance()
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var uploadPump: AudioUploadPump?
    private var notificationObservers: [NSObjectProtocol] = []
    private var speakerOverrideEnabled = false

    var isRunning: Bool {
        audioEngine != nil
    }

    func start(sendAudio: @escaping @Sendable (ThreadRealtimeAudioChunk) async -> Void) throws {
        stop()

        try configureAudioSession()

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let playerFormat = AVAudioFormat(
            standardFormatWithSampleRate: VoiceSessionAudioCodec.targetSampleRate,
            channels: 1
        )
        guard let playerFormat else {
            throw NSError(
                domain: "Litter",
                code: 3201,
                userInfo: [NSLocalizedDescriptionKey: "Failed to configure voice output format"]
            )
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playerFormat)

        let inputNode = engine.inputNode
        let outputNode = engine.outputNode
        do {
            try inputNode.setVoiceProcessingEnabled(true)
            try outputNode.setVoiceProcessingEnabled(true)
        } catch {
            NSLog("[voice] voice processing unavailable: %@", error.localizedDescription)
        }
        let inputFormat = inputNode.outputFormat(forBus: 0)
        let uploadPump = AudioUploadPump(send: sendAudio)
        self.uploadPump = uploadPump

        inputNode.installTap(onBus: 0, bufferSize: 2_048, format: inputFormat) { [weak self] buffer, _ in
            let inputLevel = VoiceSessionAudioCodec.rmsLevel(buffer: buffer)
            if let chunk = VoiceSessionAudioCodec.makeInputChunk(buffer: buffer) {
                Task { await uploadPump.enqueue(chunk) }
            }
            Task { @MainActor [weak self] in
                self?.onEvent?(.inputLevel(inputLevel))
            }
        }

        do {
            try engine.start()
            player.play()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw error
        }

        audioEngine = engine
        playerNode = player
        installAudioNotifications()
        emitRoute()
    }

    func stop() {
        clearAudioNotifications()
        uploadPump = nil

        if let inputNode = audioEngine?.inputNode {
            inputNode.removeTap(onBus: 0)
        }
        playerNode?.stop()
        audioEngine?.stop()
        playerNode = nil
        audioEngine = nil
        speakerOverrideEnabled = false

        try? session.overrideOutputAudioPort(.none)
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    func enqueueOutputAudio(_ chunk: ThreadRealtimeAudioChunk) {
        guard let playerNode,
              let buffer = VoiceSessionAudioCodec.makePlaybackBuffer(from: chunk) else {
            return
        }
        let outputLevel = VoiceSessionAudioCodec.decodePCM16Base64(
            chunk.data,
            numChannels: Int(chunk.numChannels)
        ).map(VoiceSessionAudioCodec.rmsLevel(samples:)) ?? 0
        playerNode.scheduleBuffer(buffer, completionHandler: nil)
        if !playerNode.isPlaying {
            playerNode.play()
        }
        onEvent?(.outputLevel(outputLevel))
    }

    func toggleSpeaker() throws {
        let route = currentRoute()
        guard route.supportsSpeakerToggle else { return }
        speakerOverrideEnabled.toggle()
        try session.overrideOutputAudioPort(speakerOverrideEnabled ? .speaker : .none)
        emitRoute()
    }

    private func configureAudioSession() throws {
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
        )
        try session.setActive(true)
        let route = currentRoute()
        speakerOverrideEnabled = route.supportsSpeakerToggle && route != .receiver
        if speakerOverrideEnabled {
            try session.overrideOutputAudioPort(.speaker)
        }
    }

    private func installAudioNotifications() {
        let center = NotificationCenter.default
        notificationObservers = [
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: session,
                queue: .main
            ) { [weak self] _ in
                self?.emitRoute()
            },
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: session,
                queue: .main
            ) { [weak self] notification in
                self?.handleInterruption(notification)
            },
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: session,
                queue: .main
            ) { [weak self] _ in
                self?.onEvent?(.failure("Audio services reset"))
            }
        ]
    }

    private func clearAudioNotifications() {
        let center = NotificationCenter.default
        for observer in notificationObservers {
            center.removeObserver(observer)
        }
        notificationObservers = []
    }

    private func handleInterruption(_ notification: Notification) {
        guard let rawValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawValue) else {
            return
        }

        switch type {
        case .began:
            onEvent?(.interrupted)
        case .ended:
            do {
                try session.setActive(true)
                if speakerOverrideEnabled {
                    try session.overrideOutputAudioPort(.speaker)
                }
                if let engine = audioEngine, !engine.isRunning {
                    try engine.start()
                }
                if let playerNode, !playerNode.isPlaying {
                    playerNode.play()
                }
                emitRoute()
            } catch {
                onEvent?(.failure("Failed to resume audio session"))
            }
        @unknown default:
            break
        }
    }

    private func emitRoute() {
        onEvent?(.routeChanged(currentRoute()))
    }

    private func currentRoute() -> VoiceSessionAudioRoute {
        let output = session.currentRoute.outputs.first
        let name = output?.portName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = (name?.isEmpty == false ? name! : "Audio")

        switch output?.portType {
        case .builtInSpeaker:
            return .speaker
        case .builtInReceiver:
            return .receiver
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
            return .bluetooth(fallbackName)
        case .headphones, .headsetMic, .usbAudio, .carAudio:
            return .headphones(fallbackName)
        case .airPlay:
            return .airPlay(fallbackName)
        default:
            return .unknown(fallbackName)
        }
    }
}
