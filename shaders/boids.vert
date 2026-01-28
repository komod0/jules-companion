#version 430 core

layout(location = 0) in vec2 a_position;

layout(std140, binding = 1) uniform BoidsUniforms {
    vec2 resolution;
    float time;
    float deltaTime;
    vec4 fishColor;
    vec4 backgroundColor;
    int numFish;
    int padding1;
    int padding2;
    int padding3;
};

out vec2 v_uv;

void main() {
    gl_Position = vec4(a_position.x * 2.0 - 1.0, (1.0 - a_position.y) * 2.0 - 1.0, 0.0, 1.0);
    
    vec2 uv;
    uv.y = (1.0 - a_position.y) * 2.0 - 1.0;
    uv.x = (a_position.x * 2.0 - 1.0) * (resolution.x / resolution.y);
    v_uv = uv;
}
