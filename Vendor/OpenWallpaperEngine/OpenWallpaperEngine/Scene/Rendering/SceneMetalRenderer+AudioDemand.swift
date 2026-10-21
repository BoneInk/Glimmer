import Foundation

extension SceneMetalRenderer {
    /// Whether a scene's content reads system audio, so the renderer holds capture on for it: a
    /// layer that follows audio (`g_AudioSpectrum*`, music sync, a user-bound value that may be
    /// music-synced) or a particle element with an audio response. Scripts' `registerAudioBuffers`
    /// takes its own lease (`SceneScriptAudioBuffersExtension`).
    static func needsAudio(_ analysis: SceneLayerAnalysis, particles: [SceneMetalParticleSystem]) -> Bool {
        analysis.layers.contains { $0.dependencies.contains(.audio) }
            || particles.contains(where: particleSystemReadsAudio)
    }

    static func particleSystemReadsAudio(_ system: SceneMetalParticleSystem) -> Bool {
        system.emitters.contains { $0.audio != nil }
            || system.program.operators.contains { $0.audio != nil }
            || system.program.initializers.contains { $0.audio != nil }
    }
}
