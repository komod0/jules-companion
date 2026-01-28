/**
 * Rectangle Vertex Shader - Background Rendering
 * 
 * Port of Metal's rect_vertex from Shaders.metal.
 * Used for rendering background rectangles behind text.
 */
#version 330 core

// Vertex attributes (per-vertex)
layout(location = 0) in vec2 a_position;  // Unit quad

// Instance attributes (per-instance)
layout(location = 1) in vec2 i_origin;    // Screen position in points
layout(location = 2) in vec2 i_size;      // Rectangle size in points
layout(location = 3) in vec4 i_color;     // Fill color RGBA
layout(location = 4) in float i_cornerRadius;   // Corner radius
layout(location = 5) in float i_borderWidth;    // Border width
layout(location = 6) in vec4 i_borderColor;     // Border color RGBA

// Uniforms
uniform vec2 u_viewportSize;  // Viewport size in points
uniform vec2 u_camera;        // Camera offset (scroll position)
uniform float u_scale;        // Display scale (for anti-aliasing)

// Outputs to fragment shader
out vec2 v_localPos;
out vec2 v_size;
out vec4 v_color;
out float v_cornerRadius;
out float v_borderWidth;
out vec4 v_borderColor;
out float v_scale;

void main() {
    // Scale unit quad to rectangle size
    vec2 pixelPos = i_origin + (a_position * i_size);
    
    // Apply camera/scroll offset
    pixelPos -= u_camera;
    
    // Convert to NDC
    float x = (pixelPos.x / u_viewportSize.x) * 2.0 - 1.0;
    float y = 1.0 - (pixelPos.y / u_viewportSize.y) * 2.0;
    
    gl_Position = vec4(x, y, 0.0, 1.0);
    
    // Pass data to fragment shader
    v_localPos = a_position * i_size;  // Local position within rect
    v_size = i_size;
    v_color = i_color;
    v_cornerRadius = i_cornerRadius;
    v_borderWidth = i_borderWidth;
    v_borderColor = i_borderColor;
    v_scale = u_scale;
}
