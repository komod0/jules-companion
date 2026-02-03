#include <metal_stdlib>
using namespace metal;

// =============================================================================
// Gerstner Wave Shader - Realistic Fluid Wave Animation
// =============================================================================
// Implements trochoidal (Gerstner) waves for physically accurate water motion.
// The key difference from simple sine waves is the horizontal displacement,
// which creates the characteristic sharp crests and wide troughs of real water.
//
// Mathematical basis:
//   x = x0 + Q * A * sin(k * x0 - ω * t)
//   y = A * cos(k * x0 - ω * t)
//
// Where:
//   Q = Steepness (0 = sine wave, 1/(kA) = cycloid cusp)
//   A = Amplitude
//   k = Wavenumber (2π/wavelength)
//   ω = Angular frequency (satisfies dispersion: ω = √(g*k) for deep water)
// =============================================================================

// MARK: - Data Structures

struct WaveVertex {
    float2 position [[attribute(0)]];  // Base position (x: 0-1 normalized, y: 0 or 1)
    float waveInfluence [[attribute(1)]]; // 1.0 for wave-animated edge, 0.0 for pinned edge
};

struct WaveVertexOut {
    float4 position [[position]];
    float2 uv;
    float waveHeight; // Normalized wave height for optional effects
};

// Individual wave component parameters
struct WaveParams {
    float amplitude;    // Wave height
    float wavelength;   // Distance between crests
    float steepness;    // Q factor (0-1, controls sharpness)
    float speed;        // Base speed multiplier
    float direction;    // Wave direction in radians (for 2D: positive = right)
    float phaseOffset;  // Initial phase offset
    float padding1;
    float padding2;
};

// Global uniforms
struct WaveUniforms {
    float2 viewSize;        // View dimensions in pixels
    float time;             // Animation time
    float gravity;          // Gravity constant (scaled, ~9.81)
    float4 fillColor;       // Wave fill color (RGBA)
    float4 strokeColor;     // Optional stroke color
    float strokeWidth;      // Stroke width (0 = no stroke)
    float cornerRadius;     // Top corner radius
    int waveCount;          // Number of active wave components
    int waveEdge;           // 0 = top edge wave, 1 = bottom edge wave
};

// MARK: - Constants

constant float PI = 3.14159265359;
constant float TWO_PI = 6.28318530718;

// MARK: - Gerstner Wave Functions

// Calculate the dispersion relation: ω = √(g * k)
// This ensures longer waves travel faster than shorter waves (realistic)
float calculateAngularFrequency(float wavenumber, float gravity) {
    return sqrt(gravity * wavenumber);
}

// Calculate a single Gerstner wave displacement
// Returns float2(horizontal_displacement, vertical_displacement)
float2 gerstnerWave(float x, float time, WaveParams wave, float gravity) {
    // Wavenumber k = 2π / wavelength
    float k = TWO_PI / wave.wavelength;

    // Angular frequency from dispersion relation
    float omega = calculateAngularFrequency(k, gravity) * wave.speed;

    // Phase: k*x - ω*t + offset
    float phase = k * x - omega * time + wave.phaseOffset;

    // Clamp steepness to prevent self-intersection
    // Maximum safe steepness: Q ≤ 1/(k*A)
    float maxSteepness = 1.0 / (k * wave.amplitude + 0.001);
    float Q = min(wave.steepness, maxSteepness * 0.9); // 90% of max for safety

    // Gerstner displacement
    // Horizontal: Q * A * sin(phase) - creates the "bunching" at crests
    // Vertical: A * cos(phase) - standard wave height
    float dx = Q * wave.amplitude * sin(phase);
    float dy = wave.amplitude * cos(phase);

    return float2(dx, dy);
}

// Sum multiple Gerstner waves with proper steepness constraint
// Ensures total steepness doesn't cause mesh self-intersection
float2 sumGerstnerWaves(float x,
                         float time,
                         constant WaveParams* waves,
                         int waveCount,
                         float gravity) {
    float2 totalDisplacement = float2(0.0);
    float totalSteepnessProduct = 0.0;

    // First pass: calculate total steepness contribution
    for (int i = 0; i < waveCount; i++) {
        WaveParams wave = waves[i];
        float k = TWO_PI / wave.wavelength;
        totalSteepnessProduct += wave.steepness * wave.amplitude * k;
    }

    // Normalize steepness if total exceeds safe limit
    float steepnessScale = 1.0;
    if (totalSteepnessProduct > 0.95) {
        steepnessScale = 0.95 / totalSteepnessProduct;
    }

    // Second pass: accumulate wave displacements
    for (int i = 0; i < waveCount; i++) {
        WaveParams wave = waves[i];

        // Apply steepness normalization
        WaveParams scaledWave = wave;
        scaledWave.steepness *= steepnessScale;

        float2 displacement = gerstnerWave(x, time, scaledWave, gravity);
        totalDisplacement += displacement;
    }

    return totalDisplacement;
}

// MARK: - Vertex Shader

vertex WaveVertexOut wave_vertex(WaveVertex in [[stage_in]],
                                  constant WaveUniforms& uniforms [[buffer(1)]],
                                  constant WaveParams* waves [[buffer(2)]]) {
    WaveVertexOut out;

    float2 pos = in.position;
    float influence = in.waveInfluence;

    // Calculate Gerstner wave displacement for vertices with wave influence
    if (influence > 0.5) {
        // Map normalized x (0-1) to world space for wave calculation
        // Use a larger range for wave calculation to get proper wavelength display
        float worldX = pos.x * uniforms.viewSize.x * 0.01; // Scale factor for visual appearance

        float2 waveOffset = sumGerstnerWaves(
            worldX,
            uniforms.time,
            waves,
            uniforms.waveCount,
            uniforms.gravity
        );

        // NOTE: Gerstner waves include horizontal displacement (waveOffset.x) that creates
        // realistic "bunching" at wave crests for open water. However, for bounded UI elements
        // like flash messages, this horizontal movement causes unwanted side-edge distortion/skew.
        // We intentionally only apply the vertical displacement for clean UI wave effects.

        // Apply vertical displacement based on which edge has the wave
        // Convert wave displacement to normalized view coordinates (0 to 1)
        // Scale factor converts wave amplitude units to a reasonable visual size
        // Using 0.015 for prominent, easily visible wave motion
        float verticalDisplacement = waveOffset.y * 0.015;

        if (uniforms.waveEdge == 1) {
            // Bottom edge wave: vertices start at y=0
            // waveOffset.y oscillates from -amplitude to +amplitude (due to cos)
            // Add baseline offset so wave troughs stay at or above y=0
            // Max amplitude sum is ~19, scaled by 0.015 = 0.285, so offset by ~0.3
            float baselineOffset = 0.3;
            pos.y += verticalDisplacement + baselineOffset;
        } else {
            // Top edge wave: displacement extends upward from top edge
            pos.y += verticalDisplacement;
        }

        out.waveHeight = (waveOffset.y + 1.0) * 0.5; // Normalized 0-1
    } else {
        out.waveHeight = 0.0;
    }

    // Convert to NDC
    // Input: x in [0, 1], y in [0, 1] where 0 is bottom, 1 is top
    float ndcX = pos.x * 2.0 - 1.0;
    float ndcY = pos.y * 2.0 - 1.0;

    // Aspect ratio correction (reserved for future use)
    // float aspect = uniforms.viewSize.x / uniforms.viewSize.y;

    out.position = float4(ndcX, ndcY, 0.0, 1.0);
    out.uv = in.position;

    return out;
}

// MARK: - Fragment Shader (Flat Fill)

fragment float4 wave_fragment(WaveVertexOut in [[stage_in]],
                               constant WaveUniforms& uniforms [[buffer(0)]]) {
    // Pure flat fill - vector art style
    return uniforms.fillColor;
}

// MARK: - Fragment Shader (With Subtle Gradient)

fragment float4 wave_fragment_gradient(WaveVertexOut in [[stage_in]],
                                        constant WaveUniforms& uniforms [[buffer(0)]]) {
    // Subtle vertical gradient for depth perception while maintaining flat aesthetic
    float gradient = mix(0.95, 1.0, in.uv.y);
    float3 color = uniforms.fillColor.rgb * gradient;
    return float4(color, uniforms.fillColor.a);
}

// MARK: - Fragment Shader (With Edge Highlight)

fragment float4 wave_fragment_edge(WaveVertexOut in [[stage_in]],
                                    constant WaveUniforms& uniforms [[buffer(0)]]) {
    // Add subtle edge highlight at wave top for vector stroke effect
    float edgeDistance = 1.0 - in.uv.y;
    float strokeMask = smoothstep(0.0, uniforms.strokeWidth, edgeDistance);

    float3 color = mix(uniforms.strokeColor.rgb, uniforms.fillColor.rgb, strokeMask);
    float alpha = mix(uniforms.strokeColor.a, uniforms.fillColor.a, strokeMask);

    return float4(color, alpha);
}
