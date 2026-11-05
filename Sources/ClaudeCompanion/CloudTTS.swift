import Foundation
import Security

/// Which engine speaks Claude's replies.
enum TTSProvider: String, CaseIterable, Identifiable {
    case macos, openai, elevenlabs
    var id: String { rawValue }
    var title: String {
        switch self {
        case .macos: return "macOS voices (free, on-device)"
        case .openai: return "OpenAI (gpt-4o-mini-tts)"
        case .elevenlabs: return "ElevenLabs (most human)"
        }
    }
    var keychainAccount: String? {
        switch self {
        case .macos: return nil
        case .openai: return "openai-api-key"
        case .elevenlabs: return "elevenlabs-api-key"
        }
    }
}

/// API keys live in the login Keychain under this app's service name. Never on disk in the repo.
enum Keychain {
    static let service = "com.nickbrady.claudecompanion"

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        delete(account)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecAttrLabel as String: "Claude Companion \(account)",
                                kSecValueData as String: Data(value.utf8)]
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}

/// Streams 16-bit 24 kHz mono PCM for one sentence from a cloud provider.
enum CloudTTS {
    static let sampleRate: Double = 24000

    static let openAIVoices = ["marin", "cedar", "coral", "sage", "ash", "ballad", "alloy", "echo", "fable", "nova", "onyx", "shimmer", "verse"]
    /// A few ElevenLabs premade voices (any voice ID from his ElevenLabs library also works).
    static let elevenPresets: [(name: String, id: String)] = [
        ("Rachel (calm, US)", "21m00Tcm4TlvDq8ikWAM"),
        ("George (warm, UK)", "JBFqnCBsd6RMkjVDRZzb"),
        ("Sarah (soft, US)", "EXAVITQu4vr4xnJdZ6EL"),
        ("Brian (deep, US)", "nPczCjzI2devNBz1zQrb"),
    ]

    struct Config {
        var provider: TTSProvider
        var key: String
        var openAIVoice: String
        var elevenVoiceID: String
    }

    static func request(_ text: String, _ c: Config) -> URLRequest? {
        switch c.provider {
        case .macos:
            return nil
        case .openai:
            var r = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
            r.httpMethod = "POST"
            r.setValue("Bearer \(c.key)", forHTTPHeaderField: "Authorization")
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = [
                "model": "gpt-4o-mini-tts",
                "voice": c.openAIVoice,
                "input": text,
                "response_format": "pcm",
                "instructions": "Speak like a thoughtful colleague talking out loud: warm, natural, relaxed pace, conversational.",
            ]
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
            return r
        case .elevenlabs:
            let id = c.elevenVoiceID.isEmpty ? elevenPresets[0].id : c.elevenVoiceID
            var r = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(id)/stream?output_format=pcm_24000")!)
            r.httpMethod = "POST"
            r.setValue(c.key, forHTTPHeaderField: "xi-api-key")
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = ["text": text, "model_id": "eleven_flash_v2_5"]
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
            return r
        }
    }

    /// Calls `onChunk` with little-endian Int16 PCM as it arrives. Throws on HTTP or network errors.
    static func stream(_ text: String, _ c: Config, onChunk: (Data) -> Void) async throws {
        guard let req = request(text, c) else { return }
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard let http = resp as? HTTPURLResponse else { throw TTSError.http(0, "") }
        if http.statusCode != 200 {
            var msg = Data()
            for try await b in bytes { msg.append(b); if msg.count > 600 { break } }
            throw TTSError.http(http.statusCode, String(decoding: msg, as: UTF8.self))
        }
        var buf = Data()
        var first = true
        for try await b in bytes {
            try Task.checkCancellation()
            buf.append(b)
            // ~50 ms for the first chunk (fast start), ~200 ms after that.
            if buf.count >= (first ? 2400 : 9600) {
                let even = buf.count & ~1
                onChunk(buf.prefix(even))
                buf = Data(buf.dropFirst(even))
                first = false
            }
        }
        if buf.count >= 2 { onChunk(buf.prefix(buf.count & ~1)) }
    }

    enum TTSError: LocalizedError {
        case http(Int, String)
        var errorDescription: String? {
            switch self {
            case .http(let code, let body):
                let hint = code == 401 ? " (check the API key)" : (code == 429 ? " (rate limit or out of credit)" : "")
                return "HTTP \(code)\(hint): \(body.prefix(160))"
            }
        }
    }
}
