import AVFoundation

/// Text-to-speech. AVSpeechSynthesizer renders each sentence to PCM buffers
/// (write(_:toBufferCallback:)), which we play through our own AVAudioEngine so we can
/// measure the real output amplitude and drive the orb with Claude's actual voice.
/// Sentences are queued as they stream in, so speech starts before the reply finishes.
final class SpeechOutput: NSObject {
    private let synth = AVSpeechSynthesizer()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let q = DispatchQueue(label: "speech.out")
    private let playFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
    private let cloudFormat = AVAudioFormat(standardFormatWithSampleRate: CloudTTS.sampleRate, channels: 1)!
    private var cloudQueue: [(text: String, gen: Int)] = []
    private var cloudTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var converterSource: AVAudioFormat?
    // Accessed on q only.
    private var generation = 0
    private var rendering = 0          // utterances still being synthesized
    private var scheduled = 0          // buffers queued on the player
    private var speakingFlag = false   // mirrored on main

    var voiceID: String?
    var provider: TTSProvider = .macos
    var openAIVoice = "coral"
    var elevenVoiceID = ""
    /// Main queue; a cloud voice failed and we fell back to macOS for that sentence.
    var onProviderError: ((String) -> Void)?
    /// Multiplier on the default rate (1.0 = system default).
    var rateMultiplier: Float = 1.1
    /// Main queue; fired when everything queued has been played.
    var onIdle: (() -> Void)?
    /// Main queue; output loudness 0...1, ~40 Hz while speaking.
    var onLevel: ((Float) -> Void)?

    override init() {
        super.init()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        installLevelTap()
    }

    var isSpeaking: Bool { speakingFlag }

    /// While recording, speech is queued instead of played (so the mic can't pick it up);
    /// setting this back to false plays what was queued.
    var holding = false {
        didSet {
            guard oldValue && !holding else { return }
            let queued = held
            held.removeAll()
            queued.forEach { say($0) }
        }
    }
    private(set) var held: [String] = []

    func say(_ text: String, force: Bool = false) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if holding && !force { held.append(t); return }
        if provider != .macos, let acct = provider.keychainAccount, let key = Keychain.get(acct), !key.isEmpty {
            let cfg = CloudTTS.Config(provider: provider, key: key, openAIVoice: openAIVoice, elevenVoiceID: elevenVoiceID)
            speakingFlag = true
            q.async {
                self.rendering += 1
                self.cloudQueue.append((t, self.generation))
                if self.cloudTask == nil { self.cloudTask = Task.detached { [weak self] in await self?.cloudWorker(cfg) } }
            }
            return
        }
        sayMac(t)
    }

    /// One sentence at a time: stream it (playback starts on the first ~50 ms of audio),
    /// then fetch the next while the player is still speaking.
    private func cloudWorker(_ cfg: CloudTTS.Config) async {
        while true {
            let next: (text: String, gen: Int)? = q.sync {
                if cloudQueue.isEmpty { cloudTask = nil; return nil }
                return cloudQueue.removeFirst()
            }
            guard let item = next else { return }
            var gotAudio = false
            do {
                try await CloudTTS.stream(item.text, cfg) { chunk in
                    gotAudio = true
                    self.q.async { self.scheduleInt16(chunk, gen: item.gen) }
                }
            } catch is CancellationError {
            } catch {
                let current = q.sync { item.gen == generation }
                if current {
                    DispatchQueue.main.async { self.onProviderError?(error.localizedDescription) }
                    if !gotAudio { DispatchQueue.main.async { self.sayMac(item.text) } }
                }
            }
            q.async {
                guard item.gen == self.generation else { return }
                self.rendering -= 1
                self.checkIdle()
            }
        }
    }

    // On q.
    private func scheduleInt16(_ data: Data, gen: Int) {
        guard gen == generation else { return }
        let n = data.count / 2
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: cloudFormat, frameCapacity: AVAudioFrameCount(n)) else { return }
        buf.frameLength = AVAudioFrameCount(n)
        let dst = buf.floatChannelData![0]
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<n { dst[i] = Float(Int16(littleEndian: src[i])) / 32768 }
        }
        if !engine.isRunning { try? engine.start() }
        if !player.isPlaying { player.play() }
        guard let out = convert(buf) else { return }
        scheduled += 1
        player.scheduleBuffer(out) { [weak self] in
            guard let self else { return }
            self.q.async {
                guard gen == self.generation else { return }
                self.scheduled -= 1
                self.checkIdle()
            }
        }
    }

    private func sayMac(_ t: String) {
        let u = AVSpeechUtterance(string: t)
        u.voice = voiceID.flatMap { AVSpeechSynthesisVoice(identifier: $0) } ?? SpeechOutput.defaultVoice
        u.rate = min(AVSpeechUtteranceMaximumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * rateMultiplier)
        speakingFlag = true
        q.async {
            let gen = self.generation
            self.rendering += 1
            if !self.engine.isRunning { try? self.engine.start() }
            if !self.player.isPlaying { self.player.play() }
            var ended = false
            self.synth.write(u) { [weak self] buffer in
                guard let self else { return }
                self.q.async {
                    guard gen == self.generation, !ended else { return }
                    guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                        ended = true
                        self.rendering -= 1
                        self.checkIdle()
                        return
                    }
                    guard let out = self.convert(pcm) else { return }
                    self.scheduled += 1
                    self.player.scheduleBuffer(out) { [weak self] in
                        guard let self else { return }
                        self.q.async {
                            guard gen == self.generation else { return }
                            self.scheduled -= 1
                            self.checkIdle()
                        }
                    }
                }
            }
        }
    }

    func stop() {
        held.removeAll()
        speakingFlag = false
        q.async {
            self.generation += 1
            self.cloudQueue.removeAll()
            self.cloudTask?.cancel()
            self.cloudTask = nil
            self.rendering = 0
            self.scheduled = 0
            self.synth.stopSpeaking(at: .immediate)
            self.player.stop()
            DispatchQueue.main.async { self.onLevel?(0) }
        }
    }

    private func checkIdle() {
        guard rendering == 0, scheduled == 0 else { return }
        DispatchQueue.main.async {
            self.speakingFlag = false
            self.onLevel?(0)
            self.onIdle?()
        }
    }

    private func convert(_ buf: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let src = buf.format
        if src == playFormat { return buf }
        if converterSource != src {
            converter = AVAudioConverter(from: src, to: playFormat)
            converterSource = src
        }
        guard let converter else { return nil }
        let ratio = playFormat.sampleRate / src.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: cap) else { return nil }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        return err == nil ? out : nil
    }

    private func installLevelTap() {
        let sink: (Float) -> Void = { [weak self] l in self?.onLevel?(l) }
        player.installTap(onBus: 0, bufferSize: 512, format: playFormat) { buffer, _ in
            guard let ch = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = sqrt(sum / Float(max(1, n)))
            let level = min(1, pow(rms * 6, 0.8))
            DispatchQueue.main.async { sink(level) }
        }
    }

    // MARK: - Voices

    static func englishVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted {
                if $0.quality.rawValue != $1.quality.rawValue { return $0.quality.rawValue > $1.quality.rawValue }
                if $0.language != $1.language { return $0.language == "en-US" }
                return $0.name < $1.name
            }
    }

    /// Best installed US English voice: premium > enhanced > default.
    static var defaultVoice: AVSpeechSynthesisVoice? = {
        let us = englishVoices().filter { $0.language == "en-US" }
        if let good = us.first(where: { $0.quality != .default }) { return good }
        return us.first { $0.name == "Samantha" } ?? us.first ?? AVSpeechSynthesisVoice(language: "en-US")
    }()

    static func qualityLabel(_ v: AVSpeechSynthesisVoice) -> String {
        switch v.quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Compact"
        }
    }
}

/// Turns streamed markdown into speakable sentences.
/// - Skips fenced code blocks and tables (mentions once that they're on screen).
/// - Stops speaking at a line containing only `---` (the "on-screen only" section).
/// - Strips inline markdown, links and raw URLs.
struct SpeakableStream {
    private var pending = ""      // raw text not yet classified
    private var prose = ""        // cleaned text not yet emitted as sentences
    private var inCode = false
    private var muted = false
    private var mentionedCode = false
    private var mentionedTable = false

    mutating func reset() { self = SpeakableStream() }

    mutating func feed(_ chunk: String) -> [String] {
        pending += chunk
        while let nl = pending.firstIndex(of: "\n") {
            let line = String(pending[..<nl])
            pending.removeSubrange(...nl)
            handleLine(line)
        }
        // Speak complete sentences from a long line that is still streaming in,
        // unless it could be the start of a fence / rule / table.
        let t = pending.trimmingCharacters(in: .whitespaces)
        if !inCode && !muted && t.count > 3 && !t.hasPrefix("`") && !t.hasPrefix("---") && !t.hasPrefix("|"),
           let cut = Self.lastSentenceBoundary(in: pending) {
            let head = String(pending[..<cut])
            pending.removeSubrange(..<cut)
            prose += Self.clean(head)
        }
        return drainSentences(final: false)
    }

    mutating func finish() -> [String] {
        if !pending.isEmpty { handleLine(pending); pending = "" }
        return drainSentences(final: true)
    }

    private mutating func handleLine(_ raw: String) {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("```") {
            inCode.toggle()
            if inCode && !muted && !mentionedCode {
                mentionedCode = true
                prose += " I've put the code on screen. "
            }
            return
        }
        if inCode || muted { return }
        if t == "---" || t == "***" || t == "___" { muted = true; return }
        if t.hasPrefix("|") {
            if !mentionedTable { mentionedTable = true; prose += " There's a table on screen. " }
            return
        }
        if t.isEmpty { prose += "\n"; return }
        prose += Self.clean(raw) + (Self.endsSentence(t) ? " " : ". ")
    }

    private mutating func drainSentences(final: Bool) -> [String] {
        var out: [String] = []
        if final {
            out = prose.split(separator: "\n").map { String($0) }
            prose = ""
        } else if let cut = Self.lastSentenceBoundary(in: prose) {
            out = prose[..<cut].split(separator: "\n").map { String($0) }
            prose.removeSubrange(..<cut)
        }
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.rangeOfCharacter(from: .alphanumerics) != nil }
    }

    static func endsSentence(_ s: String) -> Bool {
        guard let c = s.last else { return true }
        return ".!?:;".contains(c)
    }

    /// Index just after the last ". " / "! " / "? " / newline in s.
    static func lastSentenceBoundary(in s: String) -> String.Index? {
        var idx = s.endIndex
        var prevWasSpace = false
        while idx > s.startIndex {
            let before = s.index(before: idx)
            let c = s[before]
            if c == "\n" { return idx }
            if prevWasSpace && ".!?".contains(c) { return idx }
            prevWasSpace = (c == " ")
            idx = before
        }
        return nil
    }

    static func clean(_ s: String) -> String {
        var t = s
        // Headings / list markers / quotes at line start.
        t = t.replacingOccurrences(of: #"^\s*(#{1,6}\s+|[-*+]\s+|>\s*)"#, with: "", options: .regularExpression)
        // [text](url) -> text
        t = t.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        // raw URLs
        t = t.replacingOccurrences(of: #"https?://\S+"#, with: "a link", options: .regularExpression)
        // emphasis and inline code markers
        for m in ["**", "__", "`", "*"] { t = t.replacingOccurrences(of: m, with: "") }
        // "->" reads badly
        t = t.replacingOccurrences(of: "->", with: " to ")
        return t
    }
}
