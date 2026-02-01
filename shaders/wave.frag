#version 330 core

// =============================================================================
// Wave Fragment Shader - Styling Variants
// =============================================================================

// MARK: - Inputs
in vec2 v_uv;
in float v_waveHeight;

// MARK: - Uniforms
uniform vec4 u_fillColor;       // Wave fill color
uniform vec4 u_strokeColor;     // Stroke color
uniform float u_strokeWidth;    // Stroke width

// MARK: - Output
out vec4 fragColor;

// =============================================================================
// Variant 1: Flat Fill
// =============================================================================
void wave_fragment() {
    // Pure flat fill - vector art style
    fragColor = u_fillColor;
}

// =============================================================================
// Variant 2: With Subtle Gradient
// =============================================================================
void wave_fragment_gradient() {
    // Subtle vertical gradient for depth perception while maintaining flat aesthetic
    float gradient = mix(0.95, 1.0, v_uv.y);
    vec3 color = u_fillColor.rgb * gradient;
    fragColor = vec4(color, u_fillColor.a);
}

// =============================================================================
// Variant 3: With Edge Highlight
// =============================================================================
void wave_fragment_edge() {
    // Add subtle edge highlight at wave top for vector stroke effect
    float edgeDistance = 1.0 - v_uv.y;
    float strokeMask = smoothstep(0.0, u_strokeWidth, edgeDistance);
    
    vec3 color = mix(u_strokeColor.rgb, u_fillColor.rgb, strokeMask);
    float alpha = mix(u_strokeColor.a, u_fillColor.a, strokeMask);
    
    fragColor = vec4(color, alpha);
}

// =============================================================================
// Main Entry Point (Select variant by preprocessor define)
// =============================================================================
void main() {
    #ifdef WAVE_FRAGMENT_EDGE
        wave_fragment_edge();
    #elif defined(WAVE_FRAGMENT_GRADIENT)
        wave_fragment_gradient();
    #else
        wave_fragment();
    #endif
}
