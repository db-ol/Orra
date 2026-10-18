import Foundation

/// The voice models Orra can speak with. Each is a speech-swift product that a build
/// links or not.
nonisolated enum VoiceEngineKind: String, CaseIterable, Sendable, Identifiable {
    /// Qwen3-TTS 0.6B, see Qwen3VoiceEngine. Streams without a voice sample and needs the
    /// smaller download. The default.
    case qwen3 = "qwen3-tts"
    /// CosyVoice3 0.5B, see CosyVoiceEngine. Clones a voice sample more closely, with a
    /// larger download.
    case cosyVoice = "cosyvoice3"

    var id: String {
        rawValue
    }

    /// The model's own name, the same in every language.
    var name: String {
        switch self {
        case .qwen3: "Qwen3-TTS"
        case .cosyVoice: "CosyVoice3"
        }
    }

    /// The model and its second download: Qwen3-TTS's speech tokenizer, or CosyVoice3's
    /// speaker encoder.
    var manifests: (model: ModelManifest, codec: ModelManifest) {
        switch self {
        case .qwen3: (.qwen3Voice, .qwen3VoiceCodec)
        case .cosyVoice: (.cosyVoice, .cosyVoiceSpeaker)
        }
    }

    /// Whether the model speaks translations into `language`. Both speak English, Chinese
    /// and Spanish. CosyVoice3 does not speak Japanese well enough: in a round trip on
    /// 2026-10-18 the speech model heard other words in 45 of 55 pieces of Japanese without
    /// a voice sample, where Qwen3-TTS passed 54.
    func speaks(_ language: TranslationTarget) -> Bool {
        !(self == .cosyVoice && language == .japanese)
    }
}

/// Which voice model speaks.
nonisolated enum VoiceEngineChoice {
    /// The model of a build that has both, until the user picks the other.
    static let preferred = VoiceEngineKind.qwen3

    /// The saved model when this build has it, else the preferred one when it has that,
    /// else the one it has. Nil in a build without a voice model.
    static func resolve(saved: VoiceEngineKind?, available: [VoiceEngineKind]) -> VoiceEngineKind? {
        if let saved, available.contains(saved) {
            return saved
        }
        if available.contains(preferred) {
            return preferred
        }
        return available.first
    }
}

/// The voice models of this build and how to make one. Tests pass fakes.
struct VoiceEngines {
    /// In the order Settings lists them.
    let available: [VoiceEngineKind]
    let make: (VoiceEngineKind) -> (any SpeechSynthesizer)?

    /// A build without a voice model.
    static let none = VoiceEngines(available: []) { _ in nil }

    /// Settings offers a choice only when the build has more than one.
    var offersChoice: Bool {
        available.count > 1
    }

    /// The products this build links: Qwen3TTS, CosyVoiceTTS, both or neither. Without
    /// one, Settings says that this build cannot speak. Each runs alone at the model gate,
    /// see ExclusiveSynthesizer.
    static var live: VoiceEngines {
        var available: [VoiceEngineKind] = []
        #if canImport(Qwen3TTS)
        available.append(.qwen3)
        #endif
        #if canImport(CosyVoiceTTS)
        available.append(.cosyVoice)
        #endif
        return VoiceEngines(available: available) { kind in
            switch kind {
            case .qwen3:
                #if canImport(Qwen3TTS)
                return ExclusiveSynthesizer(Qwen3VoiceEngine())
                #else
                return nil
                #endif
            case .cosyVoice:
                #if canImport(CosyVoiceTTS)
                return ExclusiveSynthesizer(CosyVoiceEngine())
                #else
                return nil
                #endif
            }
        }
    }
}
