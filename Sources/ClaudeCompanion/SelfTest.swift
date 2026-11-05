import AppKit
import AVFoundation

/// `ClaudeCompanion --selftest [--claude]`: checks the parts that don't need a human,
/// a microphone or permissions.
enum SelfTest {
    static var failures = 0

    static func check(_ name: String, _ ok: Bool) {
        print("\(ok ? "PASS" : "FAIL")  \(name)")
        if !ok { failures += 1 }
    }

    static func run(includeClaude: Bool) -> Bool {
        gesture()
        dictation()
        holdWhileRecording()
        speakable()
        voices()
        sessions()
        if includeClaude { claude() }
        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
        return failures == 0
    }

    // Simulate cursor paths at 60 Hz.
    static func feed(_ pts: [CGPoint]) -> CGRect? {
        var d = CircleGestureDetector()
        var hit: CGRect?
        for (i, p) in pts.enumerated() { if let r = d.add(p, at: Double(i) / 60) { hit = r } }
        return hit
    }

    static func circle(center: CGPoint, r: CGFloat, frames: Int, turns: Double = 1.05, wobble: CGFloat = 0) -> [CGPoint] {
        (0..<frames).map { i in
            let th = Double(i) / Double(frames) * turns * 2 * .pi
            let rr = r + wobble * CGFloat(sin(th * 7))
            return CGPoint(x: center.x + rr * cos(th), y: center.y + rr * sin(th))
        }
    }

    static func gesture() {
        let c = CGPoint(x: 800, y: 500)
        let hit = feed(circle(center: c, r: 80, frames: 50))
        check("circle (r=80, 0.8s) detected", hit != nil)
        if let hit { check("circle bbox ≈ 160pt around target", abs(hit.width - 160) < 20 && hit.contains(c)) }
        check("wobbly hand-drawn circle detected", feed(circle(center: c, r: 120, frames: 70, wobble: 12)) != nil)
        check("clockwise circle detected", feed(circle(center: c, r: 60, frames: 45).map { CGPoint(x: $0.x, y: 2 * c.y - $0.y) }) != nil)
        check("half circle ignored", feed(circle(center: c, r: 80, frames: 40, turns: 0.5)) == nil)
        check("straight line ignored", feed((0..<60).map { CGPoint(x: 100 + CGFloat($0) * 8, y: 300) }) == nil)
        check("zig-zag scribble ignored", feed((0..<90).map { CGPoint(x: 300 + CGFloat($0) * 4, y: $0 % 10 < 5 ? 300 : 340) }) == nil)
        var shake: [CGPoint] = []
        for i in 0..<90 {
            let k = CGFloat(i % 6) * 15
            let x: CGFloat = (i % 12 < 6) ? k : 90 - k
            shake.append(CGPoint(x: 400 + x, y: 300 + CGFloat(i)))
        }
        check("back-and-forth shake ignored", feed(shake) == nil)
        check("tiny jitter ignored", feed(circle(center: c, r: 6, frames: 40)) == nil)
        check("too-slow circle (4s) ignored", feed(circle(center: c, r: 80, frames: 240)) == nil)
    }

    /// Long dictation: partials grow, reset after pauses, tasks end and restart.
    static func dictation() {
        var a = TranscriptAccumulator()
        // Task 1: growing partials, then a pause makes the recognizer start a fresh phrase.
        for p in ["So", "So the story", "So the story is about", "So the story is about a migration we did."] { a.update(p) }
        for p in ["It", "It took three", "It took three months"] { a.update(p) }          // reset (lost before the fix)
        a.update("It took three months, and we used")
        // Task 2 after rollover; task 1's final arrives late, after task 2 has started.
        a.update("Using", task: 2)
        a.update("It took three months, and we used it daily.", task: 0)                   // late final of task 1
        for p in ["Using an expanded", "Using an expanded python notebook to be better."] { a.update(p, task: 2) }
        let full = a.text
        print("      dictated: \(full)")
        check("dictation keeps first phrase", full.hasPrefix("So the story is about a migration we did."))
        check("dictation keeps phrase after a pause reset", full.contains("It took three months, and we used it daily."))
        check("late final lands in order", full.hasSuffix("used it daily. Using an expanded python notebook to be better."))
        check("dictation keeps text after task restart", full.hasSuffix("Using an expanded python notebook to be better."))
        var b = TranscriptAccumulator()
        for p in ["i think", "I think we", "I think we should"] { b.update(p) }                // revision, not reset
        check("revisions don't duplicate text", b.text == "I think we should")
        var c = TranscriptAccumulator()
        for p in ["They cut", "They cut off my message", "They cut off my message somehow you did"] { c.update(p) }
        c.update("It cut off my message somehow you did")                                   // first-word correction
        check("first-word correction isn't doubled", c.text == "It cut off my message somehow you did")
        var d = TranscriptAccumulator()
        d.update("The other thing as far as", start: 0.4, end: 2.1)
        d.update("The other thing as far as the deadline goes", start: 0.4, end: 3.0)        // timed revision
        d.update("we should ship Friday", start: 4.2, end: 5.6)                               // timed new phrase
        var h = TranscriptAccumulator()
        h.update("this is what I said before the pause", task: 3)
        h.update("", task: 3)                                                                  // empty final
        check("empty final keeps the task's last partial", h.text == "this is what I said before the pause")
        var f = TranscriptAccumulator()
        f.update("write a"); f.update("right")                                               // short-phrase rewrite
        check("short-phrase rewrite isn't a new phrase", f.text == "right")
        var g = TranscriptAccumulator()
        g.update("we should ship the parser on Friday"); g.update("we should ship the parser Friday")
        check("near-same-length revision isn't doubled", g.text == "we should ship the parser Friday")
        var e = TranscriptAccumulator()
        e.update("I want to fix the bug in the parser today")
        e.update("and the")                                                                  // new phrase sharing a word
        check("short new phrase sharing words isn't lost", e.text == "I want to fix the bug in the parser today and the")
        check("timestamps separate phrases", d.text == "The other thing as far as the deadline goes we should ship Friday")
        check("multi-line text typed into iTerm becomes one line", ITerm.singleLine("one\ntwo\r\nthree\u{2028} four") == "one two three four")
    }

    /// Replies arriving mid-recording are queued, not played into the mic.
    static func holdWhileRecording() {
        let out = SpeechOutput()
        out.holding = true
        out.say("This reply arrived while you were talking.")
        check("reply speech is held while recording", out.held.count == 1 && !out.isSpeaking)
        out.stop()
        check("held speech is dropped on barge-in stop", out.held.isEmpty)
    }

    static func speakable() {
        var s = SpeakableStream()
        var out: [String] = []
        let reply = "Sure. The bug is in **main.swift**, line 12. Here's the fix:\n```swift\nlet x = 1\n```\nThat should do it! See [the docs](https://example.com).\n---\nDetails: run `make test`."
        // Stream in small chunks like the real API.
        var i = reply.startIndex
        while i < reply.endIndex {
            let j = reply.index(i, offsetBy: 7, limitedBy: reply.endIndex) ?? reply.endIndex
            out += s.feed(String(reply[i..<j]))
            i = j
        }
        out += s.finish()
        let spoken = out.joined(separator: " | ")
        print("      spoken: \(spoken)")
        check("speaks first sentence early", out.first == "Sure.")
        check("strips markdown emphasis", !spoken.contains("**"))
        check("skips code, mentions it once", !spoken.contains("let x") && spoken.contains("code on screen"))
        check("link text kept, URL dropped", spoken.contains("the docs") && !spoken.contains("example.com"))
        check("stops at --- (screen-only section)", !spoken.contains("make test"))
    }

    static func voices() {
        let v = SpeechOutput.englishVoices()
        check("found English TTS voices (\(v.count))", !v.isEmpty)
        if let d = SpeechOutput.defaultVoice { print("      default voice: \(d.name) [\(SpeechOutput.qualityLabel(d))]") }
        // Render (not play) a sentence to buffers to prove the amplitude path works.
        let synth = AVSpeechSynthesizer()
        let u = AVSpeechUtterance(string: "Testing the orb.")
        u.voice = SpeechOutput.defaultVoice
        var frames: AVAudioFrameCount = 0
        var peak: Float = 0
        let done = DispatchSemaphore(value: 0)
        var finished = false
        synth.write(u) { buf in
            guard let pcm = buf as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 { if !finished { finished = true; done.signal() }; return }
            frames += pcm.frameLength
            if let f = pcm.floatChannelData?[0] {
                for k in 0..<Int(pcm.frameLength) { peak = max(peak, abs(f[k])) }
            } else if let i16 = pcm.int16ChannelData?[0] {
                for k in 0..<Int(pcm.frameLength) { peak = max(peak, abs(Float(i16[k]) / 32768)) }
            }
        }
        let deadline = Date().addingTimeInterval(8)
        while done.wait(timeout: .now()) == .timedOut && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        check("TTS renders to PCM buffers for the voice orb (\(frames) frames, peak \(String(format: "%.2f", peak)))", frames > 1000 && peak > 0.01)
    }

    static func sessions() {
        let s = SessionCatalog.recent(limit: 5)
        check("reads recent Claude Code sessions (\(s.count))", !s.isEmpty)
        for x in s.prefix(3) { print("      \(x.folderName) — \(x.snippet) (\(x.ageText))") }
        check("finds claude CLI", (try? ClaudeBridge.locateClaude()) != nil)
    }

    /// Real round trip through `claude -p` stream-json with an image attached. Uses a little quota.
    static func claude() {
        // A 64x64 image: left half red, right half blue.
        let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 64))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 32, y: 0, width: 32, height: 64))
        let att = ScreenCapture.makeAttachment(ctx.makeImage()!, label: "test")!

        let tmp = FileManager.default.temporaryDirectory
        let bridge = ClaudeBridge(launch: .init(cwd: tmp, model: "haiku",
                                                extraArgs: ["--tools", "", "--strict-mcp-config", "--no-session-persistence"]))
        var text = "", started = false, done = false, error: String?
        bridge.onEvent = { e in
            switch e {
            case .started: started = true
            case .text(let t): text += t
            case .done(let isErr, let m): done = true; if isErr { error = m }
            case .exited(let m): done = true; error = m
            case .tool: break
            }
        }
        do {
            try bridge.send(text: "What two colors are in this image, left then right? Answer in five words or fewer.", images: [ClaudeBridge.Image(mediaType: "image/jpeg", data: att.jpeg)])
        } catch { check("claude bridge started", false); return }
        let deadline = Date().addingTimeInterval(90)
        while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        bridge.stop()
        print("      claude said: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        check("claude session started (init event)", started)
        check("claude reply streamed, no error", done && error == nil && !text.isEmpty)
        check("claude saw the image (red, blue)", text.lowercased().contains("red") && text.lowercased().contains("blue"))
    }
}
