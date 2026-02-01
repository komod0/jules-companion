#version 330 core

// =============================================================================
// Gerstner Wave Shader - Realistic Fluid Wave Animation (GLSL Port)
// =============================================================================
// Ported from macOS Metal implementation
// Implements trochoidal (Gerstner) waves for physically accurate water motion
// =============================================================================

// MARK: - Inputs
layout(location = 0) in vec2 a_position;        // Base position (x: 0-1, y: 0 or 1)
layout(location = 1) in float a_waveInfluence; // 1.0 = wave edge, 0.0 = pinned

// MARK: - Outputs
out vec2 v_uv;
out float v_waveHeight;

// MARK: - Constants
const float PI = 3.14159265359;
const float TWO_PI = 6.28318530718;

// MARK: - Wave Parameters
struct WaveParams {
    float amplitude;
    float wavelength;
    float steepness;
    float speed;
    float direction;
    float phaseOffset;
    float padding1;
    float padding2;
};

// MARK: - Uniforms
layout(std140) uniform WaveUniforms {
    vec2 u_viewSize;        // View dimensions in pixels
    float u_time;           // Animation time
    float u_gravity;        // Gravity constant (~9.81)
    vec4 u_fillColor;       // Wave fill color (RGBA)
    vec4 u_strokeColor;     // Stroke color
    float u_strokeWidth;    // Stroke width (0 = no stroke)
    float u_cornerRadius;   // Corner radius
    int u_waveCount;        // Number of active waves
    int u_waveEdge;         // 0 = top edge, 1 = bottom edge
};

// Individual wave components (max 8 waves)
uniform WaveParams u_waves[8];

// MARK: - Gerstner Wave Functions

// Calculate dispersion relation: ω = √(g * k)
float calculateAngularFrequency(float wavenumber, float gravity) {
    return sqrt(gravity * wavenumber);
}

// Calculate a single Gerstner wave displacement
// Returns vec2(horizontal_displacement, vertical_displacement)
vec2 gerstnerWave(float x, float time, WaveParams wave, float gravity) {
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
    
    return vec2(dx, dy);
}

// Sum multiple Gerstner waves with proper steepness constraint
vec2 sumGerstnerWaves(float x, float time, int waveCount, float gravity) {
    vec2 totalDisplacement = vec2(0.0);
    float totalSteepnessProduct = 0.0;
    
    // First pass: calculate total steepness contribution
    for (int i = 0; i < waveCount; i++) {
        WaveParams wave = u_waves[i];
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
        WaveParams wave = u_waves[i];
        
        // Apply steepness normalization
        WaveParams scaledWave = wave;
        scaledWave.steepness *= steepnessScale;
        
        vec2 displacement = gerstnerWave(x, time, scaledWave, gravity);
        totalDisplacement += displacement;
    }
    
    return totalDisplacement;
}

// MARK: - Main
void main() {
    vec2 pos = a_position;
    float influence = a_waveInfluence;
    
    // Calculate Gerstner wave displacement for vertices with wave influence
    if (influence > 0.5) {
        // Map normalized x (0-1) to world space for wave calculation
        // Use a larger range for wave calculation to get proper wavelength display
        float worldX = pos.x * u_viewSize.x * 0.01; // Scale factor for visual appearance
        
        vec2 waveOffset = sumGerstnerWaves(worldX, u_time, u_waveCount, u_gravity);
        
        // NOTE: For UI elements, we only apply vertical displacement (not horizontal)
        // to prevent side-edge distortion/skew
        
        // Convert wave displacement to normalized view coordinates
        // Scale factor converts wave amplitude units to reasonable visual size
        float verticalDisplacement = waveOffset.y * 0.015;
        
        if (u_waveEdge == 1) {
            // Bottom edge wave: vertices start at y=0
            // Add baseline offset so wave troughs stay at or above y=0
            float baselineOffset = 0.3;
            pos.y += verticalDisplacement + baselineOffset;
        } else {
            // Top edge wave: displacement extends upward from top edge
            pos.y += verticalDisplacement;
        }
        
        v_waveHeight = (waveOffset.y + 1.0) * 0.5; // Normalized 0-1
    } else {
        v_waveHeight = 0.0;
    }
    
    // Convert to NDC (Normalized Device Coordinates)
    // OpenGL: (-1,-1) is bottom-left, (1,1) is top-right
    // Input: x in [0, 1], y in [0, 1] where 0 is bottom, 1 is top
    float ndcX = pos.x * 2.0 - 1.0;
    float ndcY = pos.y * 2.0 - 1.0;
    
    gl_Position = vec4(ndcX, ndcY, 0.0, 1.0);
    
    // Pass UV coordinates
    v_uv = a_position;
}
