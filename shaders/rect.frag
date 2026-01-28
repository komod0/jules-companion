/**
 * Rectangle Fragment Shader - Rounded Corners & Borders
 * 
 * Port of Metal's rect_fragment from Shaders.metal.
 * Supports rounded corners and optional borders with anti-aliasing.
 */
#version 330 core

// Inputs from vertex shader
in vec2 v_localPos;
in vec2 v_size;
in vec4 v_color;
in float v_cornerRadius;
in float v_borderWidth;
in vec4 v_borderColor;
in float v_scale;

// Output
out vec4 fragColor;

/**
 * Signed distance function for rounded rectangle.
 * Returns negative inside, positive outside, zero on edge.
 */
float sdRoundedRect(vec2 p, vec2 halfSize, float radius) {
    vec2 q = abs(p) - halfSize + radius;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius;
}

void main() {
    // For simple rects without corner radius or border, just output fill color
    if (v_cornerRadius <= 0.0 && v_borderWidth <= 0.0) {
        fragColor = v_color;
        return;
    }
    
    // Calculate position relative to rect center
    vec2 center = v_size * 0.5;
    vec2 p = v_localPos - center;
    vec2 halfSize = center;
    
    // Clamp corner radius to half of smallest dimension
    float radius = min(v_cornerRadius, min(halfSize.x, halfSize.y));
    
    // Calculate signed distance
    float d = sdRoundedRect(p, halfSize, radius);
    
    // Anti-aliasing width (0.5 physical pixels)
    float aa = 0.5 / v_scale;
    
    // If we have a border
    if (v_borderWidth > 0.0) {
        // Outside the shape - discard
        if (d > aa) {
            discard;
        }
        
        // Inside border region
        float innerD = d + v_borderWidth;
        
        if (innerD < -aa) {
            // Fully inside fill region
            fragColor = v_color;
        } else if (d < -aa) {
            // In border region
            fragColor = v_borderColor;
        } else {
            // On outer edge - anti-alias border
            float alpha = 1.0 - smoothstep(-aa, aa, d);
            fragColor = vec4(v_borderColor.rgb, v_borderColor.a * alpha);
        }
    } else {
        // No border - just rounded fill
        if (d > aa) {
            discard;
        }
        
        // Anti-alias the edge
        float alpha = 1.0 - smoothstep(-aa, aa, d);
        fragColor = vec4(v_color.rgb, v_color.a * alpha);
    }
}
