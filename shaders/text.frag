/**
 * Text Fragment Shader - Font Atlas Sampling
 * 
 * Port of Metal's text_fragment from Shaders.metal.
 * Samples the R8 font atlas and applies instance color.
 */
#version 330 core

// Inputs from vertex shader
in vec2 v_uv;
in vec4 v_color;

// Uniforms
uniform sampler2D u_atlas;  // R8 font atlas texture

// Output
out vec4 fragColor;

void main() {
    // Sample alpha from R8 texture (coverage value)
    float alpha = texture(u_atlas, v_uv).r;
    
    // Apply instance color with alpha
    fragColor = vec4(v_color.rgb, v_color.a * alpha);
}
