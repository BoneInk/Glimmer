import Foundation

/// "On battery: use a lower quality preset" (Settings › Performance › Playback): the quality
/// preset applied while the Mac runs on battery or in Low Power Mode. `keepSettings` changes no
/// quality setting, so only the frame rate cap applies.
enum GSBatteryPreset: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case keepSettings, low, medium, high

    /// The quality preset, nil for the user's own settings.
    var quality: GSQuality? {
        switch self {
        case .keepSettings: return nil
        case .low: return .low
        case .medium: return .medium
        case .high: return .high
        }
    }
}

/// The frame rate cap while the battery quality applies; `none` leaves the frame rate to the
/// preset and the user's FPS. The caps divide 60 and 120 Hz evenly (`FramePacing.cadence`).
enum GSBatteryFrameRate: Int, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case none = 0, fps15 = 15, fps20 = 20, fps30 = 30
}

/// The settings wallpapers render with: the stored settings, lowered while the Mac runs on battery
/// or in Low Power Mode when "On battery: use a lower quality preset" is on. Only an overlay: the
/// stored settings, the Preset control and what is saved stay the user's, and come back on AC.
enum BatteryQuality {
    /// Whether the battery quality applies in `power`.
    static func applies(_ settings: GlobalSettings, power: PowerState) -> Bool {
        settings.batteryQuality && (power.onBattery || power.lowPowerMode)
    }

    /// `settings` as wallpapers render them in `power`.
    static func effective(_ settings: GlobalSettings, power: PowerState) -> GlobalSettings {
        applies(settings, power: power) ? lowered(settings) : settings
    }

    /// `settings` with the battery preset and frame rate cap applied. Each setting only goes down:
    /// a setting already lower than the preset's keeps the user's value, so the battery preset
    /// never raises quality. Render resolution, upscaling and texture resolution stay the user's
    /// (the presets set them to full quality).
    static func lowered(_ settings: GlobalSettings) -> GlobalSettings {
        var result = settings
        if let quality = settings.batteryQualityPreset.quality {
            let preset = GlobalSettingsViewModel.applying(quality, to: settings)
            result.shadows = lower(settings.shadows, preset.shadows, by: \.level)
            result.volumetrics = lower(settings.volumetrics, preset.volumetrics, by: \.level)
            result.antiAliasing = lower(settings.antiAliasing, preset.antiAliasing, by: \.sampleCount)
            result.postProcessing = lower(settings.postProcessing, preset.postProcessing, by: \.rank)
            result.reflections = settings.reflections && preset.reflections
            result.particleBudget = lower(settings.particleBudget, preset.particleBudget) { $0.limit ?? .max }
            result.fps = min(settings.fps, preset.fps)
            // A higher stop is the efficiency end.
            result.qualityEfficiency = max(settings.qualityEfficiency, preset.qualityEfficiency)
        }
        if settings.batteryFrameRateCap != .none {
            result.fps = min(result.fps, Double(settings.batteryFrameRateCap.rawValue))
        }
        // A lowered rate or stop is the battery's, not one the user set: the stop's caps apply.
        if result.fps != settings.fps || result.qualityEfficiency != settings.qualityEfficiency {
            result.fpsSetByUser = false
        }
        return result
    }

    private static func lower<Value, Rank: Comparable>(_ user: Value, _ preset: Value,
                                                       by rank: (Value) -> Rank) -> Value {
        rank(preset) < rank(user) ? preset : user
    }
}

private extension GSPostProcessingQuality {
    /// Cost order: disabled < enabled < ultra < displayhdr.
    var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}
