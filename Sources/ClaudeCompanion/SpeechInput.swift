import AVFoundation
import Speech

/// Joins recognizer output into one transcript for long dictation.
///
/// SFSpeechRecognizer loses earlier speech in two ways:
///  - after a pause, partial results "reset" and only contain the newest phrase;
///  - a task ends (isFinal / error / ~1 min limit), and later audio needs a new task.
/// Recognition tasks overlap briefly when we hand over (the old one's final can arrive after
/// the new one has started), so text is kept per task, in task order.
struct TranscriptAccumulator {
    private struct Slot {
        var committed = ""
        var current = ""
        var currentEnd: Double = 0
        var text: String { [committed, current].filter { !$0.isEmpty }.joined(separator: " ") }
    }
    private var slots: [Int: Slot] = [:]

    /// Everything recognition task `task` contributed (its last non-empty result wins; the
    /// empty "final" results the on-device recognizer sometimes sends are ignored).
    func text(forTask task: Int) -> String { slots[task]?.text ?? "" }

    var text: String {
        slots.keys.sorted().compactMap { k -> String? in
            let t = slots[k]!.text
            return t.isEmpty ? nil : t
        }.joined(separator: " ")
    }

    /// A new partial (or final) result from recognition task `task`. `start`/`end` are the audio
    /// timestamps of its first word and the end of its last word (0 when the recognizer doesn't
    /// report timing). Returns true if it was treated as a new phrase within that task.
    @discardableResult
    mutating func update(_ partial: String, task: Int = 0, start: Double = 0, end: Double = 0) -> Bool {
        let t = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        var s = slots[task] ?? Slot()
        var reset = false
        if !s.current.isEmpty {
            if start > 0 && s.currentEnd > 0 {
                reset = start >= s.currentEnd - 0.05      // timing is authoritative
            } else {
                reset = Self.isReset(from: s.current, to: t)
            }
        }
        if reset {
            s.committed = s.committed.isEmpty ? s.current : s.committed + " " + s.current
        }
        s.current = t
        s.currentEnd = end
        slots[task] = s
        return reset
    }

    /// Text-only fallback. Corrections ("They cut off…" → "It cut off…") have about the same
    /// length and share most words, so they never count as a new phrase. Only a clearly
    /// shorter result with different words does (and never for short phrases, where the
    /// recognizer rewrites freely).
    static func isReset(from old: String, to new: String) -> Bool {
        let a = words(old), b = words(new)
        guard a.count >= 4, !b.isEmpty, b.count < a.count else { return false }
        if a.starts(with: b) { return false }                       // just a shorter re-read
        if b.count * 2 <= a.count { return true }                   // revisions don't halve
        let setA = Set(a)
        let overlap = Double(b.filter { setA.contains($0) }.count) / Double(b.count)
        return overlap < 0.5 && Double(b.count) <= Double(a.count) * 0.7
    }

    private static func words(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
    }
}

/// Holds the request the audio tap feeds, so tasks can be swapped without stopping the mic.
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var req: SFSpeechAudioBufferRecognitionRequest?
    private var _paused = false
    /// While true the mic keeps running but audio isn't sent to the recognizer.
    var paused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _paused }
        set { lock.lock(); _paused = newValue; lock.unlock() }
    }
    var request: SFSpeechAudioBufferRecognitionRequest? {
        get { lock.lock(); defer { lock.unlock() }; return req }
        set { lock.lock(); req = newValue; lock.unlock() }
    }
}

/// Microphone -> on-device SFSpeechRecognizer. Only runs between start() and stop().
/// Long dictation: the mic stays on and recognition tasks are chained with no audio gap
/// (the next request is fed before the previous one is closed); text accumulates per task.
@MainActor
final class SpeechInput {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private let box = RequestBox()
    private var tasks: [Int: (task: SFSpeechRecognitionTask, request: SFSpeechAudioBufferRecognitionRequest)] = [:]
    private var acc = TranscriptAccumulator()
    private var recording = false
    private var stopping = false
    private var taskGeneration = 0
    private var stopGeneration = 0
    private var rolloverTimer: Timer?
    private var contextual: [String] = []
    private var finalWaiter: CheckedContinuation<Void, Never>?

    /// Main queue.
    var onPartial: ((String) -> Void)?
    /// Main queue, 0...1 RMS-ish level for the UI.
    var onLevel: ((Float) -> Void)?

    var isOnDevice: Bool { recognizer?.supportsOnDeviceRecognition == true }
    var isRecording: Bool { recording }
    /// Stop feeding the recognizer (e.g. while a reply plays out loud), without stopping the mic.
    var feedPaused: Bool {
        get { box.paused }
        set { if box.paused != newValue { box.paused = newValue; DiagLog.log("stt.feed", newValue ? "paused" : "resumed") } }
    }

    nonisolated static func requestPermissions() async -> (mic: Bool, speech: Bool) {
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        let speech: Bool = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        return (mic, speech)
    }

    func start(contextualStrings: [String] = []) throws {
        cancel()
        acc = TranscriptAccumulator()
        contextual = contextualStrings
        guard let recognizer, recognizer.isAvailable else { throw InputError.recognizerUnavailable }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw InputError.noMicrophone }
        input.removeTap(onBus: 0)
        Self.installTap(on: input, format: format, box: box, level: onLevel)
        engine.prepare()
        try engine.start()
        recording = true
        stopping = false
        startTask()
    }

    /// Start the next recognition task and make the mic feed it *before* closing the previous
    /// one, so no audio falls between them.
    private func startTask(closing previous: Int? = nil) {
        guard let recognizer, recording else { return }
        taskGeneration += 1
        let gen = taskGeneration
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        req.taskHint = .dictation
        req.contextualStrings = contextual
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        let task = recognizer.recognitionTask(with: req, resultHandler: Self.handler(gen: gen, owner: self))
        tasks[gen] = (task, req)
        box.request = req                                        // mic now feeds the new request
        if let previous { tasks[previous]?.request.endAudio() }  // then close the old one

        // Recognition tasks cap out around a minute: hand over before that.
        rolloverTimer?.invalidate()
        rolloverTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.recording, !self.stopping, gen == self.taskGeneration else { return }
                DiagLog.log("stt.rollover", "task=\(gen) at 50s")
                self.startTask(closing: gen)
            }
        }
    }

    /// Builds the recognizer callback outside the main actor (it runs on a background queue)
    /// and hops to main for all state changes.
    nonisolated private static func handler(gen: Int, owner: SpeechInput) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        weak var weakOwner = owner
        return { result, error in
            let text = result?.bestTranscription.formattedString
            let segs = result?.bestTranscription.segments ?? []
            let start = segs.first?.timestamp ?? 0
            let end = segs.last.map { $0.timestamp + $0.duration } ?? 0
            let isFinal = result?.isFinal ?? false
            let errText = error.map { "\($0.localizedDescription) [\(($0 as NSError).code)]" }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    weakOwner?.handle(gen: gen, text: text, start: start, end: end, isFinal: isFinal, errText: errText)
                }
            }
        }
    }

    private func handle(gen: Int, text: String?, start: Double, end: Double, isFinal: Bool, errText: String?) {
        guard tasks[gen] != nil else { return }             // cancelled / finished
        if let text {
            let wasReset = acc.update(text, task: gen, start: start, end: end)
            DiagLog.log(isFinal ? "stt.final" : "stt.partial",
                        "task=\(gen) t=\(String(format: "%.2f-%.2f", start, end))\(wasReset ? " NEW-PHRASE" : "") \"\(text.suffix(200))\"")
            onPartial?(acc.text)
        }
        if let errText { DiagLog.log("stt.error", "task=\(gen) \(errText)") }
        guard isFinal || errText != nil else { return }
        let kept = acc.text(forTask: gen)
        DiagLog.log("stt.task-done", "task=\(gen) final=\((text ?? "").isEmpty ? "empty (kept last partial)" : "text") kept \(kept.count) chars: \"\(kept)\"")
        tasks[gen] = nil
        if stopping {
            if tasks.isEmpty { resumeWaiter() }
        } else if recording && gen == taskGeneration {
            // The recognizer ended the live task on its own (pause / limit): chain the next.
            DiagLog.log("stt.chain", "task \(gen) ended mid-recording, starting next")
            startTask()
        }
    }

    /// The recognizer can lag seconds behind speech (on-device, long dictation), so wait for
    /// every open task's final result, up to `maxWait`, instead of cutting off the tail.
    func stop(maxWait: Double = 8) async -> String {
        guard recording, !stopping else { return acc.text }   // one stop at a time
        stopping = true
        stopGeneration += 1
        let myStop = stopGeneration
        let t0 = Date()
        rolloverTimer?.invalidate()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        box.request = nil
        for (_, t) in tasks { t.request.endAudio() }
        if !tasks.isEmpty {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                finalWaiter = c
                DispatchQueue.main.asyncAfter(deadline: .now() + maxWait) { [weak self] in
                    MainActor.assumeIsolated {
                        // Only this stop's timeout may resume this stop's waiter.
                        guard let self, self.stopGeneration == myStop, self.finalWaiter != nil else { return }
                        DiagLog.log("stt.final-timeout", "no final result after \(maxWait)s, using last partial")
                        self.resumeWaiter()
                    }
                }
            }
        }
        recording = false
        stopping = false
        for (_, t) in tasks { t.task.cancel() }
        tasks.removeAll()
        DiagLog.log("stt.stopped", "waited \(String(format: "%.2f", Date().timeIntervalSince(t0)))s, \(acc.text.count) chars")
        return acc.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() {
        recording = false
        stopping = false
        stopGeneration += 1
        rolloverTimer?.invalidate()
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        box.request = nil
        for (_, t) in tasks { t.request.endAudio(); t.task.cancel() }
        tasks.removeAll()
        resumeWaiter()
    }

    private func resumeWaiter() {
        finalWaiter?.resume()
        finalWaiter = nil
    }

    /// The tap runs on an audio thread; it only touches the lock-protected box.
    nonisolated private static func installTap(on input: AVAudioInputNode, format: AVAudioFormat,
                                               box: RequestBox, level levelSink: ((Float) -> Void)?) {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            if !box.paused { box.request?.append(buffer) }
            guard let ch = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in stride(from: 0, to: n, by: 4) { sum += ch[i] * ch[i] }
            let rms = sqrt(sum / Float(max(1, n / 4)))
            let level = min(1, rms * 12)
            DispatchQueue.main.async { levelSink?(level) }
        }
    }

    enum InputError: LocalizedError {
        case recognizerUnavailable, noMicrophone
        var errorDescription: String? {
            switch self {
            case .recognizerUnavailable: return "Speech recognition isn't available right now (check Speech Recognition permission)."
            case .noMicrophone: return "No microphone input available (check Microphone permission)."
            }
        }
    }
}
