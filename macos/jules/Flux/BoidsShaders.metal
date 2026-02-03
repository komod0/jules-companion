#include <metal_stdlib>
using namespace metal;

// =============================================================================
// Boids Background Shader - Lightweight, Reusable Fish Animation
// =============================================================================
// A high-performance Metal shader for rendering a boids (fish schooling)
// animation as a background layer. Designed for easy integration into any view.
// =============================================================================

// --- Data Structures ---

struct BoidsUniforms {
    float2 resolution;       // Viewport size in pixels
    float time;              // Elapsed time in seconds
    float4 fishColor;        // RGBA color for fish
    float4 backgroundColor;  // RGBA background color
    int numFish;             // Number of active fish
    int padding1;
    int padding2;
    int padding3;
};

struct BoidParticle {
    float2 position;         // Position in normalized coordinates (-aspect..aspect, -1..1)
    float2 velocity;         // Velocity vector
};

struct BoidsVertexOut {
    float4 position [[position]];
    float2 uv;               // Coordinate system: x: -aspect..aspect, y: -1..1
};

// --- Utility Functions ---

// Fast pseudo-random hash
inline float boids_hash(float n) {
    return fract(sin(n) * 43758.5453123);
}

// Smooth minimum for blending SDFs
inline float boids_smin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

// =============================================================================
// Boids Compute Kernel - GPU-accelerated flocking simulation
// =============================================================================
// Implements Craig Reynolds' Boids algorithm with three steering behaviors:
// 1. Separation - Avoid crowding neighbors
// 2. Alignment  - Steer towards average heading of neighbors
// 3. Cohesion   - Steer towards center of mass of neighbors
// =============================================================================

kernel void boids_update(device BoidParticle* particles [[buffer(0)]],
                         constant BoidsUniforms& uniforms [[buffer(1)]],
                         uint id [[thread_position_in_grid]]) {

    int numFish = uniforms.numFish;
    if (id >= uint(numFish)) return;

    BoidParticle p = particles[id];
    float2 pos = p.position;
    float2 vel = p.velocity;

    // Steering forces
    float2 separation = float2(0);
    float2 alignment = float2(0);
    float2 cohesion = float2(0);
    float2 center = float2(0);
    int count = 0;

    // Perception radii
    constexpr float r_sep = 0.1;
    constexpr float r_align = 0.3;

    // Compute steering forces from neighbors
    for (int i = 0; i < numFish; i++) {
        if (i == int(id)) continue;

        BoidParticle other = particles[i];
        float d = distance(pos, other.position);

        if (d < r_sep) {
            // Separation: steer away from close neighbors
            separation += (pos - other.position) / (d + 0.0001);
        }
        if (d < r_align) {
            // Alignment: match neighbor velocity
            alignment += other.velocity;
            // Cohesion: track neighbor positions
            center += other.position;
            count++;
        }
    }

    // Average and normalize steering forces
    if (count > 0) {
        alignment /= float(count);
        center /= float(count);
        cohesion = center - pos;
    }

    if (length(alignment) > 0) alignment = normalize(alignment);
    if (length(cohesion) > 0) cohesion = normalize(cohesion);
    if (length(separation) > 0) separation = normalize(separation);

    // Base weights
    float w_sep = 1.5;
    float w_align = 1.0;
    float w_coh = 0.8;

    // Solo fish behavior (15% are independent swimmers)
    float randId = boids_hash(float(id) * 0.123);
    bool isSolo = randId > 0.85;

    if (isSolo) {
        w_sep = 2.0;
        w_align = 0.2;
        w_coh = 0.0;
    }

    // Apply steering forces
    float2 accel = separation * w_sep + alignment * w_align + cohesion * w_coh;

    // Add procedural turbulence (water current simulation)
    float time = uniforms.time;
    constexpr float noiseScale = 4.0;
    float nX = sin(pos.y * noiseScale + time + float(id)) * cos(pos.x * noiseScale + time * 0.5);
    float nY = cos(pos.x * noiseScale + time + float(id)) * sin(pos.y * noiseScale + time * 0.5);

    float noiseForce = 0.2;

    if (isSolo) {
        // Solo fish dart erratically
        float dartTimer = floor(time * 4.0 + randId * 10.0);
        float dartRand = boids_hash(dartTimer);

        if (dartRand > 0.7) {
            noiseForce = 4.0;
            nX = sin(dartTimer * 12.3);
            nY = cos(dartTimer * 45.6);
        } else {
            noiseForce = 0.5;
        }
    }

    accel += float2(nX, nY) * noiseForce;

    // Boundary handling
    float aspect = uniforms.resolution.x / uniforms.resolution.y;
    float margin = 0.1;
    float xLimit = aspect + margin;
    float yLimit = 1.0 + margin;

    // Reset fish that go off-screen
    bool needsReset = pos.y > yLimit || pos.x < -xLimit || pos.x > xLimit;

    if (needsReset) {
        float spawnChoice = boids_hash(float(id) + time * 0.1);

        if (spawnChoice < 0.7) {
            // Spawn from bottom (70%)
            pos.y = -yLimit - 0.5;
            pos.x = boids_hash(float(id) + time) * (aspect * 1.6) - (aspect * 0.8);
            vel.x = (boids_hash(float(id) * 2.0 + time) - 0.5) * 0.004;
            vel.y = abs(vel.y) * 0.5 + 0.002;
        } else {
            // Spawn from sides (30%)
            bool fromLeft = boids_hash(float(id) * 3.0 + time) > 0.5;
            pos.x = fromLeft ? -xLimit - 0.3 : xLimit + 0.3;
            pos.y = boids_hash(float(id) + time * 0.5) * 1.6 - 0.8;
            vel.x = fromLeft ? 0.003 : -0.003;
            vel.y = 0.002;
        }
    }

    // Floor boundary
    if (pos.y < -yLimit) {
        pos.y = -yLimit;
        vel.y = abs(vel.y) * 0.5;
    }

    // Physics integration
    constexpr float dt = 0.016; // ~60fps timestep
    vel += accel * dt;

    // Speed limits
    float speed = length(vel);
    float maxSpeed = isSolo ? 0.010 : 0.005;
    constexpr float minSpeed = 0.005;

    if (speed > maxSpeed) {
        vel = normalize(vel) * maxSpeed;
    } else if (speed < minSpeed && speed > 0.0001) {
        vel = normalize(vel) * minSpeed;
    }

    // Update position with upward drift
    pos += vel;
    pos.y += 0.012; // Simulates camera descent / fish rising

    // Write back
    particles[id].position = pos;
    particles[id].velocity = vel;
}

// =============================================================================
// Vertex Shader - Full-screen quad positioning
// =============================================================================

vertex BoidsVertexOut boids_vertex(const device float2* positions [[buffer(0)]],
                                   uint vid [[vertex_id]],
                                   constant BoidsUniforms& uniforms [[buffer(1)]]) {
    BoidsVertexOut out;
    float2 pos = positions[vid];

    // Convert 0..1 to NDC (-1..1)
    out.position = float4(pos.x * 2.0 - 1.0, (1.0 - pos.y) * 2.0 - 1.0, 0.0, 1.0);

    // UV in aspect-corrected coordinate space
    float2 uv;
    uv.y = (1.0 - pos.y) * 2.0 - 1.0;
    uv.x = (pos.x * 2.0 - 1.0) * (uniforms.resolution.x / uniforms.resolution.y);
    out.uv = uv;

    return out;
}

// =============================================================================
// Fragment Shader - Renders fish with motion blur trails
// =============================================================================

fragment float4 boids_fragment(BoidsVertexOut in [[stage_in]],
                               constant BoidsUniforms& uniforms [[buffer(0)]],
                               device BoidParticle* particles [[buffer(1)]]) {
    float2 uv = in.uv;
    int numFish = uniforms.numFish;

    // Start with background color
    float3 color = uniforms.backgroundColor.rgb;
    float3 fishColor = uniforms.fishColor.rgb;

    constexpr float aa = 0.005; // Anti-aliasing width

    // Culling radius: max trail + body
    constexpr float cullRadius = 0.5 + 0.02 + 0.013;

    // Render each fish
    for (int j = 0; j < numFish; j++) {
        BoidParticle p = particles[j];
        float2 p_now = p.position;

        // Early culling - skip fish far from this pixel
        float2 toFish = uv - p_now;
        float distSq = dot(toFish, toFish);
        if (distSq > cullRadius * cullRadius) continue;

        float2 vel = p.velocity;
        float velLen = length(vel);
        float speed = velLen * 60.0; // Normalized speed at 60fps

        // Fish orientation
        float2 dir = (velLen > 0.0001) ? vel / velLen : float2(0.0, 1.0);

        constexpr float bodyRadius = 0.013;

        // Motion blur trail
        constexpr float speedThreshold = 0.4;
        float trailAlpha = 0.0;

        if (speed > speedThreshold) {
            constexpr float maxTrail = 0.5;
            float extra = (speed - speedThreshold) * 0.4;
            float trailLen = min(extra, maxTrail);

            float2 tailPos = p_now - dir * trailLen;
            float2 pa = toFish;
            float2 ba = tailPos - p_now;
            float baDotBa = dot(ba, ba);
            float h = (baDotBa > 0.0001) ? clamp(dot(pa, ba) / baDotBa, 0.0, 1.0) : 0.0;
            float rTaper = bodyRadius * (1.0 - h * 0.8);
            float dSeg = length(pa - ba * h) - rTaper;
            trailAlpha = 1.0 - smoothstep(0.0, aa, dSeg);
        }

        // Fish body (capsule SDF)
        constexpr float bodyLen = 0.02;
        float2 bodyTail = p_now - dir * bodyLen;

        float2 pa_b = toFish;
        float2 ba_b = bodyTail - p_now;
        float baDotBa_b = dot(ba_b, ba_b);
        float h_b = (baDotBa_b > 0.0001) ? clamp(dot(pa_b, ba_b) / baDotBa_b, 0.0, 1.0) : 0.0;
        float dBody = length(pa_b - ba_b * h_b) - bodyRadius;

        float bodyAlpha = 1.0 - smoothstep(0.0, aa, dBody);

        // Blend trail and body
        color = mix(color, fishColor * 0.6, trailAlpha * 0.6);
        color = mix(color, fishColor, bodyAlpha);
    }

    return float4(color, uniforms.backgroundColor.a);
}

// =============================================================================
// Alternative Fragment Shader - Minimal version for maximum performance
// =============================================================================
// Use this when you need the absolute highest performance (e.g., many fish)
// Renders only fish bodies without motion blur trails.

fragment float4 boids_fragment_minimal(BoidsVertexOut in [[stage_in]],
                                       constant BoidsUniforms& uniforms [[buffer(0)]],
                                       device BoidParticle* particles [[buffer(1)]]) {
    float2 uv = in.uv;
    int numFish = uniforms.numFish;

    float3 color = uniforms.backgroundColor.rgb;
    float3 fishColor = uniforms.fishColor.rgb;

    constexpr float aa = 0.005;
    constexpr float bodyRadius = 0.015;
    constexpr float cullRadius = bodyRadius * 3.0;

    for (int j = 0; j < numFish; j++) {
        BoidParticle p = particles[j];
        float2 toFish = uv - p.position;

        float distSq = dot(toFish, toFish);
        if (distSq > cullRadius * cullRadius) continue;

        float d = sqrt(distSq) - bodyRadius;
        float alpha = 1.0 - smoothstep(0.0, aa, d);

        color = mix(color, fishColor, alpha);
    }

    return float4(color, uniforms.backgroundColor.a);
}
