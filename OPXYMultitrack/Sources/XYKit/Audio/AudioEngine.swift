// AudioEngine.swift — the live engine: input, monitoring, transport, metronome and recording.
//
// It never owns the project. The store hands it the current Project when something changes,
// and the engine reports back finished takes through `onTake`.

import AVFoundation
import CoreAudio

public final class AudioEngine: ObservableObject {
    @Published public private(set) var isRunning = false
    @Published public private(set) var isPlaying = false
    @Published public private(set) var isRecording = false
    @Published public private(set) var hasInput = false
    @Published public var status = "Starting…"
    @Published public private(set) var inputDevices: [AudioDevice] = []
    @Published public private(set) var selectedInputID: AudioDeviceID?
    @Published public private(set) var preview: RecordingPreview?
    /// Hear the input through the armed track's effects. Off by default unless the input is an OP-XY,
    /// so a laptop microphone never feeds back through the speakers.
    @Published public var monitorEnabled = false { didSet { routeInput() } }

    public let meters = MeterHub()
    public let clock = TransportClock()
    public let registry: EffectRegistry
    public var projectProvider: (() -> (project: Project, package: ProjectPackage))?
    public var onTake: ((Take) -> Void)?

    private var engine: AVAudioEngine?
    private var graph: MixGraph?
    private var inputMixer: AVAudioMixerNode?
    private var sink: AVAudioMixerNode?
    private var clickPlayer: AVAudioPlayerNode?
    private var clickTick: AVAudioPCMBuffer?
    private var clickAccent: AVAudioPCMBuffer?
    private var format: AVAudioFormat?
    private var armedIndex: Int?
    private var previousDefaultInput: AudioDeviceID?
    private var deviceLatency: Double = 0
    private var configObserver: NSObjectProtocol?
    private var displayTimer: Timer?
    private var restartWork: DispatchWorkItem?
    private var tickCount = 0
    private var autoStopAt: Double?

    // Shared with the input tap thread; always read and written under `lock`.
    private let lock = NSLock()
    private var segments: [PlaySegment] = []
    private var startHost: UInt64 = 0
    private var session: RecordingSession?

    private final class RecordingSession {
        let trackID: UUID
        let assetID = UUID()
        let url: URL
        var file: AVAudioFile?
        let recordStart: Double
        let latency: Double
        var started = false
        var frames: AVAudioFramePosition = 0
        var accumulator = PeakAccumulator()
        var failure: String?

        init(trackID: UUID, url: URL, file: AVAudioFile, recordStart: Double, latency: Double) {
            self.trackID = trackID
            self.url = url
            self.file = file
            self.recordStart = recordStart
            self.latency = latency
        }
    }

    public init(registry: EffectRegistry) {
        self.registry = registry
        CoreAudioDevices.onDeviceListChange { [weak self] in self?.devicesChanged() }
    }

    // MARK: Devices

    private static func looksLikeOPXY(_ device: AudioDevice) -> Bool {
        device.name.localizedCaseInsensitiveContains("XY") || device.name.localizedCaseInsensitiveContains("OP-")
    }

    private func reloadDevices() {
        inputDevices = CoreAudioDevices.inputs()
        if let id = selectedInputID, !inputDevices.contains(where: { $0.id == id }) {
            selectedInputID = nil
        }
        if selectedInputID == nil, let xy = inputDevices.first(where: Self.looksLikeOPXY) {
            selectedInputID = xy.id
            monitorEnabled = true
        }
    }

    private func devicesChanged() {
        let before = selectedInputID
        reloadDevices()
        if before != selectedInputID {
            if before != nil, selectedInputID == nil { status = "Input disconnected. Anything recorded so far is kept." }
            scheduleRestart()
        }
    }

    public func selectInput(_ id: AudioDeviceID?) {
        selectedInputID = id
        if id == nil { monitorEnabled = false }
        start()
    }

    private func scheduleRestart() {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.start() }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // MARK: Engine lifecycle

    /// Build a fresh engine for the current project. Safe to call again after a device or project change.
    public func start() {
        guard let context = projectProvider?() else { return }
        stopEngine()
        reloadDevices()
        let project = context.project
        guard let format = AVAudioFormat(standardFormatWithSampleRate: project.sampleRate, channels: 2) else { return }

        // Same approach as monitor.swift: make the instrument the Mac's default input and let the engine
        // use system defaults on both sides, rather than pinning devices on the engine's audio unit.
        let outputID = CoreAudioDevices.defaultDevice(input: false)
        var wantInput = false
        var note: String?
        if let inputID = selectedInputID {
            if inputID == outputID {
                note = "The Mac's output is set to \(CoreAudioDevices.name(inputID)). Choose speakers or headphones in Sound settings to record."
            } else {
                if previousDefaultInput == nil { previousDefaultInput = CoreAudioDevices.defaultDevice(input: true) }
                CoreAudioDevices.setDefaultInput(inputID)
                wantInput = true
            }
        }

        let engine = AVAudioEngine()
        let graph = MixGraph(engine: engine, format: format, trackCount: Project.trackCount)
        let click = AVAudioPlayerNode()
        let sink = AVAudioMixerNode()
        engine.attach(click)
        engine.attach(sink)
        engine.connect(click, to: engine.mainMixerNode, format: format)
        engine.connect(sink, to: engine.mainMixerNode, format: format)
        sink.outputVolume = 0

        // Input path: device → inputMixer (converted to the project format) → armed track, or a silent sink.
        // The mixer is always connected to something so its tap keeps running; the tap is the dry recording feed.
        var inputMixer: AVAudioMixerNode?
        if wantInput {
            let hardware = engine.inputNode.inputFormat(forBus: 0)
            if hardware.sampleRate > 0, hardware.channelCount > 0 {
                let inputFormat = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate,
                                                channels: hardware.channelCount) ?? hardware
                let mixer = AVAudioMixerNode()
                engine.attach(mixer)
                engine.connect(engine.inputNode, to: mixer, format: inputFormat)
                engine.connect(mixer, to: sink, fromBus: 0, toBus: 0, format: format)
                mixer.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, when in
                    self?.handleInput(buffer, when)
                }
                inputMixer = mixer
            } else {
                note = "The input has no usable format. Check Microphone permission in System Settings."
            }
        }

        let meters = self.meters
        for (index, strip) in graph.strips.enumerated() {
            strip.fader.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
                meters.push(index, buffer: buffer)
            }
        }
        graph.outMixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            meters.push(MeterHub.master, buffer: buffer)
        }

        graph.sync(project: project, registry: registry)
        graph.loadFiles(project: project, package: context.package)

        engine.prepare()
        do {
            try engine.start()
        } catch {
            status = "Could not start audio: \(error.localizedDescription)"
            return
        }

        self.engine = engine
        self.graph = graph
        self.format = format
        self.clickPlayer = click
        self.sink = sink
        self.inputMixer = inputMixer
        self.clickTick = Self.makeClick(format: format, frequency: 1000)
        self.clickAccent = Self.makeClick(format: format, frequency: 1600)
        hasInput = inputMixer != nil
        isRunning = true
        routeInput()

        deviceLatency = 0
        if hasInput, let inputID = selectedInputID, let outputID {
            deviceLatency = CoreAudioDevices.latencySeconds(inputID, input: true)
                          + CoreAudioDevices.latencySeconds(outputID, input: false)
        }

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            // The hardware changed under us (unplugged, sample rate switched). Keep the take, then rebuild.
            self?.stop()
            self?.scheduleRestart()
        }

        if let note {
            status = note
        } else if hasInput, let inputID = selectedInputID {
            let out = outputID.map(CoreAudioDevices.name) ?? "output"
            status = "\(CoreAudioDevices.name(inputID)) → \(out)  ·  \(Int(project.sampleRate)) Hz  ·  \(Int((deviceLatency * 1000).rounded())) ms reported latency"
        } else {
            status = "No input selected. Playback only."
        }
        startDisplayTimer()
    }

    private func stopEngine() {
        stop()
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine?.stop()
        engine = nil
        graph = nil
        inputMixer = nil
        sink = nil
        clickPlayer = nil
        hasInput = false
        isRunning = false
    }

    /// Call when the app quits: stops audio and gives the Mac its previous default input back.
    public func shutdown() {
        stopEngine()
        displayTimer?.invalidate()
        if let previous = previousDefaultInput { CoreAudioDevices.setDefaultInput(previous) }
        previousDefaultInput = nil
    }

    /// The project file changed (open, new): drop the old graph and build one for the new project.
    public func reload() { start() }

    // MARK: Monitoring

    public func setArmed(index: Int?) {
        armedIndex = index
        routeInput()
    }

    private func routeInput() {
        guard let engine, let graph, let inputMixer, let sink, let format else { return }
        engine.disconnectNodeOutput(inputMixer)
        if monitorEnabled, let index = armedIndex, graph.strips.indices.contains(index) {
            // Into the armed track ahead of its effects, so you hear the take the way it will play back.
            engine.connect(inputMixer, to: graph.strips[index].pre, fromBus: 0, toBus: 1, format: format)
        } else {
            engine.connect(inputMixer, to: sink, fromBus: 0, toBus: 0, format: format)
        }
    }

    // MARK: Project changes

    public func sync(project: Project, old: Project, reschedule: Bool) {
        graph?.sync(project: project, registry: registry)
        guard reschedule, isPlaying, !isRecording else { return }
        let clipsChanged = old.tracks.map(\.clips) != project.tracks.map(\.clips)
        if clipsChanged || old.bpm != project.bpm || old.cycle != project.cycle || old.metronome != project.metronome {
            play(from: currentPosition())
        }
    }

    /// After a drag ends: pick up whatever moved while rescheduling was held off.
    public func rescheduleIfPlaying() {
        if isPlaying, !isRecording { play(from: currentPosition()) }
    }

    // MARK: Transport

    public func currentPosition() -> Double {
        guard isPlaying else { return clock.position }
        lock.lock()
        defer { lock.unlock() }
        return positionLocked(atHost: mach_absolute_time())
    }

    private func positionLocked(atHost host: UInt64) -> Double {
        guard var current = segments.first else { return 0 }
        let elapsed = host >= startHost
            ? AVAudioTime.seconds(forHostTime: host - startHost)
            : -AVAudioTime.seconds(forHostTime: startHost - host)
        for segment in segments {
            if segment.t0 <= elapsed { current = segment } else { break }
        }
        return current.a + (elapsed - current.t0)
    }

    /// Start (or restart) playback from a project position. One clock: every player and the metronome
    /// begin at the same host time, so tracks cannot drift against each other.
    public func play(from position: Double, useCycle: Bool = true, countInUntil: Double? = nil) {
        guard let graph, let clickPlayer, isRunning, let context = projectProvider?() else { return }
        let project = context.project
        graph.stopPlayers()
        clickPlayer.stop()
        graph.loadFiles(project: project, package: context.package)

        var plan: [PlaySegment] = []
        let cycle = project.cycle
        let cycleLength = cycle.end - cycle.start
        if useCycle, cycle.enabled, cycleLength > 0.05, position < cycle.end {
            // Unroll the cycle ahead of time so each repeat is sample-tight, with no stop-and-restart gap.
            plan.append(PlaySegment(a: position, b: cycle.end, t0: 0))
            var t = cycle.end - position
            while t < 1200 {
                plan.append(PlaySegment(a: cycle.start, b: cycle.end, t0: t))
                t += cycleLength
            }
            autoStopAt = nil
        } else {
            plan = [PlaySegment(a: position, b: .infinity, t0: 0)]
            let end = project.endTime
            autoStopAt = (end > 0 && position < end) ? end + 0.5 : nil
        }

        graph.schedule(project: project, segments: plan)
        scheduleClicks(project: project, segments: plan, countInUntil: countInUntil)

        let host = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.1)
        let when = AVAudioTime(hostTime: host)
        graph.startPlayers(at: when)
        clickPlayer.play(at: when)

        lock.lock()
        segments = plan
        startHost = host
        lock.unlock()
        isPlaying = true
    }

    public func stop() {
        if isRecording { stopRecording() }
        guard isPlaying else { return }
        let position = max(0, currentPosition())
        graph?.stopPlayers()
        clickPlayer?.stop()
        isPlaying = false
        clock.position = position
    }

    public func seek(to position: Double) {
        guard !isRecording else { return }
        if isPlaying {
            play(from: max(0, position))
        } else {
            clock.position = max(0, position)
        }
    }

    // MARK: Metronome

    private static func makeClick(format: AVAudioFormat, frequency: Double) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(format.sampleRate * 0.03)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let data = buffer.floatChannelData else { return nil }
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            let t = Double(i) / format.sampleRate
            let sample = Float(sin(2 * .pi * frequency * t) * exp(-t * 140) * 0.5)
            for c in 0..<Int(format.channelCount) { data[c][i] = sample }
        }
        return buffer
    }

    private func scheduleClicks(project: Project, segments: [PlaySegment], countInUntil: Double?) {
        guard let clickPlayer, let clickTick, let clickAccent, let format else { return }
        guard project.metronome || countInUntil != nil else { return }
        let beat = project.timebase.secondsPerBeat
        let perBar = project.beatsPerBar
        for segment in segments {
            let end = min(segment.b, segment.a + 600)
            var n = Int((segment.a / beat - 1e-9).rounded(.up))
            while Double(n) * beat < end - 1e-9 {
                let t = Double(n) * beat
                if project.metronome || t < (countInUntil ?? -Double.infinity) - 1e-6 {
                    let downbeat = ((n % perBar) + perBar) % perBar == 0
                    let frame = AVAudioFramePosition(((segment.t0 + t - segment.a) * format.sampleRate).rounded())
                    clickPlayer.scheduleBuffer(downbeat ? clickAccent : clickTick,
                                               at: AVAudioTime(sampleTime: max(0, frame), atRate: format.sampleRate),
                                               options: [])
                }
                n += 1
            }
        }
    }

    // MARK: Recording

    /// Record the dry input onto a track. From a standstill this plays a one-bar count-in first (if enabled);
    /// while already playing it punches in at the playhead.
    public func record(trackID: UUID) {
        guard isRunning, !isRecording, let format, let context = projectProvider?() else { return }
        guard hasInput else {
            status = "No input to record. Connect the OP-XY or pick an input."
            return
        }
        let project = context.project
        let package = context.package
        let recordStart = max(0, currentPosition())

        // Dry audio, in the project format, straight into the package.
        let fileName = "\(UUID().uuidString).wav"
        let url = package.audioDir.appendingPathComponent(fileName)
        let file: AVAudioFile
        do {
            try package.ensureDirectories()
            file = try AVAudioFile(forWriting: url, settings: AudioFiles.wavFloatSettings(sampleRate: format.sampleRate),
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            status = "Cannot create the recording file: \(error.localizedDescription)"
            return
        }
        let latency = deviceLatency + project.latencyOffsetMs / 1000
        let newSession = RecordingSession(trackID: trackID, url: url, file: file,
                                          recordStart: recordStart, latency: latency)

        if !isPlaying {
            let preRoll = project.countIn ? project.timebase.secondsPerBar : 0
            play(from: recordStart - preRoll, useCycle: false, countInUntil: project.countIn ? recordStart : nil)
        } else {
            lock.lock()
            let cycling = segments.count > 1
            lock.unlock()
            if cycling { play(from: recordStart, useCycle: false) }   // takes are linear; leave the cycle
        }
        autoStopAt = nil

        lock.lock()
        session = newSession
        lock.unlock()
        isRecording = true
        preview = RecordingPreview(trackID: trackID, start: recordStart, duration: 0, peaks: [])
    }

    /// Punch out. Playback carries on; the finished take is handed to `onTake`.
    public func stopRecording() {
        lock.lock()
        let finished = session
        session = nil
        lock.unlock()
        isRecording = false
        preview = nil
        guard let finished, let format else { return }

        finished.file = nil                                   // releasing the file closes it
        let duration = Double(finished.frames) / format.sampleRate
        guard finished.frames > 0 else {
            try? FileManager.default.removeItem(at: finished.url)
            return
        }
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let asset = Asset(id: finished.assetID, fileName: finished.url.lastPathComponent,
                          name: "Take \(stamp)", duration: duration)
        if let failure = finished.failure { status = "Recording stopped early: \(failure). The take so far is kept." }
        onTake?(Take(trackID: finished.trackID, asset: asset, start: finished.recordStart,
                     peaks: finished.accumulator.finish()))
    }

    /// Runs on the tap's thread (not the realtime render thread), so writing to disk here is fine.
    private func handleInput(_ buffer: AVAudioPCMBuffer, _ when: AVAudioTime) {
        meters.push(MeterHub.input, buffer: buffer)
        lock.lock()
        defer { lock.unlock() }
        guard let session, let file = session.file, session.failure == nil else { return }

        var skip = 0
        if !session.started {
            // Latency compensation. The sound in this buffer was played against what the musician heard
            // `latency` seconds ago, so treat it as belonging that much earlier, and only start writing
            // once that corrected position reaches the punch-in point. The clip then sits exactly at recordStart.
            if when.isHostTimeValid {
                let corrected = positionLocked(atHost: when.hostTime) - session.latency
                let short = session.recordStart - corrected
                if short > 0 { skip = Int((short * buffer.format.sampleRate).rounded()) }
            }
            if skip >= Int(buffer.frameLength) { return }
            session.started = true
        }

        do {
            if skip > 0, let trimmed = AudioFiles.slice(buffer, from: skip) {
                try file.write(from: trimmed)
            } else {
                try file.write(from: buffer)
            }
            session.frames += AVAudioFramePosition(Int(buffer.frameLength) - skip)
            session.accumulator.append(buffer, from: skip)
        } catch {
            // Most likely a full disk. Stop cleanly on the main thread and keep what was written.
            session.failure = error.localizedDescription
            DispatchQueue.main.async { [weak self] in self?.stopRecording() }
        }
    }

    // MARK: Display timer

    private func startDisplayTimer() {
        guard displayTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.displayTick() }
        RunLoop.main.add(timer, forMode: .common)             // keeps running while a knob or clip is dragged
        displayTimer = timer
    }

    private func displayTick() {
        meters.tick()
        tickCount += 1
        guard isPlaying else { return }
        let position = currentPosition()
        clock.position = position

        if isRecording, tickCount % 3 == 0, let format {
            lock.lock()
            let live = session.map { ($0.trackID, $0.recordStart, $0.frames, $0.accumulator.peaks) }
            lock.unlock()
            if let live {
                preview = RecordingPreview(trackID: live.0, start: live.1,
                                           duration: Double(live.2) / format.sampleRate, peaks: live.3)
            }
        }
        if let end = autoStopAt, position >= end, !isRecording {
            stop()
        }
    }
}
