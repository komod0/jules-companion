/**
 * Text Vertex Shader - Instanced Quad Rendering
 * 
 * Port of Metal's text_vertex from Shaders.metal.
 * Uses instanced rendering with one quad (6 vertices) per glyph.
 */
#version 330 core

// Vertex attributes (per-vertex)
layout(location = 0) in vec2 a_position;  // Unit quad: (0,0), (1,0), (0,1), (1,0), (1,1), (0,1)

// Instance attributes (per-instance)
layout(location = 1) in vec2 i_origin;    // Screen position in points
layout(location = 2) in vec2 i_size;      // Glyph size in points
layout(location = 3) in vec2 i_uvMin;     // Texture UV top-left
layout(location = 4) in vec2 i_uvMax;     // Texture UV bottom-right
layout(location = 5) in vec4 i_color;     // RGBA color

// Uniforms
uniform vec2 u_viewportSize;  // Viewport size in points
uniform vec2 u_camera;        // Camera offset (scroll position)

// Outputs to fragment shader
out vec2 v_uv;
out vec4 v_color;

void main() {
    // Scale unit quad to glyph size
    vec2 pixelPos = i_origin + (a_position * i_size);
    
    // Apply camera/scroll offset
    pixelPos -= u_camera;
    
    // Convert to NDC (Normalized Device Coordinates)
    // (0,0) is top-left in our logic, (-1,1) is top-left in OpenGL NDC
    float x = (pixelPos.x / u_viewportSize.x) * 2.0 - 1.0;
    float y = 1.0 - (pixelPos.y / u_viewportSize.y) * 2.0;  // Flip Y
    
    gl_Position = vec4(x, y, 0.0, 1.0);
    
    // Interpolate UV coordinates
    v_uv = mix(i_uvMin, i_uvMax, a_position);
    
    // Pass through color
    v_color = i_color;
}
