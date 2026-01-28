#version 430 core

struct BoidParticle {
    vec2 position;
    vec2 velocity;
};

layout(std430, binding = 0) readonly buffer ParticleBuffer {
    BoidParticle particles[];
};

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

uniform int u_renderMode;

in vec2 v_uv;
out vec4 fragColor;

const float AA_WIDTH = 0.005;
const float BODY_RADIUS = 0.013;
const float BODY_LEN = 0.02;
const float CULL_RADIUS = 0.5 + BODY_RADIUS * 2.0;
const float SPEED_THRESHOLD = 0.4;
const float MAX_TRAIL = 0.5;

void main() {
    vec3 color = backgroundColor.rgb;
    vec3 fColor = fishColor.rgb;

    if (u_renderMode == 0) {
        for (int j = 0; j < numFish; j++) {
            BoidParticle p = particles[j];
            vec2 p_now = p.position;

            vec2 toFish = v_uv - p_now;
            float distSq = dot(toFish, toFish);
            if (distSq > CULL_RADIUS * CULL_RADIUS) continue;

            vec2 vel = p.velocity;
            float velLen = length(vel);
            float speed = velLen * 60.0;

            vec2 dir = (velLen > 0.0001) ? vel / velLen : vec2(0.0, 1.0);

            float trailAlpha = 0.0;

            if (speed > SPEED_THRESHOLD) {
                float extra = (speed - SPEED_THRESHOLD) * 0.4;
                float trailLen = min(extra, MAX_TRAIL);

                vec2 tailPos = p_now - dir * trailLen;
                vec2 pa = toFish;
                vec2 ba = tailPos - p_now;
                float baDotBa = dot(ba, ba);
                float h = (baDotBa > 0.0001) ? clamp(dot(pa, ba) / baDotBa, 0.0, 1.0) : 0.0;
                float rTaper = BODY_RADIUS * (1.0 - h * 0.8);
                float dSeg = length(pa - ba * h) - rTaper;
                trailAlpha = 1.0 - smoothstep(0.0, AA_WIDTH, dSeg);
            }

            vec2 bodyTail = p_now - dir * BODY_LEN;
            vec2 pa_b = toFish;
            vec2 ba_b = bodyTail - p_now;
            float baDotBa_b = dot(ba_b, ba_b);
            float h_b = (baDotBa_b > 0.0001) ? clamp(dot(pa_b, ba_b) / baDotBa_b, 0.0, 1.0) : 0.0;
            float dBody = length(pa_b - ba_b * h_b) - BODY_RADIUS;

            float bodyAlpha = 1.0 - smoothstep(0.0, AA_WIDTH, dBody);

            color = mix(color, fColor * 0.6, trailAlpha * 0.6);
            color = mix(color, fColor, bodyAlpha);
        }
    } else {
        const float minimalRadius = 0.015;
        const float minimalCull = minimalRadius * 3.0;

        for (int j = 0; j < numFish; j++) {
            BoidParticle p = particles[j];
            vec2 toFish = v_uv - p.position;

            float distSq = dot(toFish, toFish);
            if (distSq > minimalCull * minimalCull) continue;

            float d = sqrt(distSq) - minimalRadius;
            float alpha = 1.0 - smoothstep(0.0, AA_WIDTH, d);

            color = mix(color, fColor, alpha);
        }
    }

    fragColor = vec4(color, backgroundColor.a);
}
