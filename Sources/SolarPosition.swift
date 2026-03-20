import Foundation

/// Maps time-of-day to gradient texture indices for lighting
struct SolarPosition {
    /// Gradient textures in order: midnight, dawn, sunrise, mid morning, noon, late afternoon, sunset, dusk
    /// Each corresponds to ~3 hours of the day

    struct LightingState {
        let gradientIndexA: Int
        let gradientIndexB: Int
        let mix: Float  // 0 = fully A, 1 = fully B
    }

    /// Get lighting state for a given hour (0-24)
    static func lighting(forHour hour: Float) -> LightingState {
        // Map hours to gradient indices:
        // 0:00  = solar midnight (0)
        // 3:00  = dawn (1)
        // 6:00  = sunrise (2)
        // 9:00  = mid morning (3)
        // 12:00 = solar noon (4)
        // 15:00 = late afternoon (5)
        // 18:00 = sunset (6)
        // 21:00 = dusk (7)

        let normalizedHour = hour.truncatingRemainder(dividingBy: 24.0)
        let segment = normalizedHour / 3.0  // 0-8
        let indexA = Int(segment) % 8
        let indexB = (indexA + 1) % 8
        let mix = segment - Float(Int(segment))

        return LightingState(gradientIndexA: indexA, gradientIndexB: indexB, mix: mix)
    }

    /// Get lighting state that smoothly transitions through the full day cycle
    /// progress: 0-1 maps to midnight → midnight (full day)
    static func lighting(forDayProgress progress: Float) -> LightingState {
        return lighting(forHour: progress * 24.0)
    }
}
