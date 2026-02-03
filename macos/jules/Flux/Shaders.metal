#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float2 position [[attribute(0)]]; // Base Quad Position (0,0 to 1,1)
};

struct InstanceData {
    float2 origin;   // Screen Position (x, y)
    float2 size;     // Size of the glyph quad
    float2 uvMin;    // Texture UV TopLeft
    float2 uvMax;    // Texture UV BottomRight
    float4 color;    // RGBA
};

struct Uniforms {
    float2 viewportSize;
    float cameraX;
    float cameraY;
    float scale;    // Retina scale factor for proper anti-aliasing
    float padding;  // Padding to align struct
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
};

// ---------------------------
// Text Pass (Instanced Quads)
// ---------------------------

vertex VertexOut text_vertex(const VertexIn vertexIn [[stage_in]],
                             const device InstanceData* instances [[buffer(1)]],
                             constant Uniforms& uniforms [[buffer(2)]],
                             uint instanceID [[instance_id]]) {
    VertexOut out;
    InstanceData instance = instances[instanceID];

    // Scale unit quad to size
    float2 pixelPos = instance.origin + (vertexIn.position * instance.size);

    // Apply scrolling
    pixelPos.x -= uniforms.cameraX;
    pixelPos.y -= uniforms.cameraY;

    // NDC Conversion
    // (0,0) is Top-Left in our logic, (-1, 1) is Top-Left in Metal NDC
    float x = (pixelPos.x / uniforms.viewportSize.x) * 2.0 - 1.0;
    float y = (1.0 - (pixelPos.y / uniforms.viewportSize.y) * 2.0); // Flip Y

    out.position = float4(x, y, 0.0, 1.0);

    // UV mapping
    // vertexIn.position is 0..1
    // We interpolate between uvMin and uvMax
    out.uv = mix(instance.uvMin, instance.uvMax, vertexIn.position);

    out.color = instance.color;
    return out;
}

fragment float4 text_fragment(VertexOut in [[stage_in]],
                              texture2d<float> atlas [[texture(0)]]) {
    // Use nearest-neighbor filtering for crisp text rendering
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::nearest);

    // Sample Alpha from R8 texture
    float alpha = atlas.sample(s, in.uv).r;

    // Tint with instance color
    return float4(in.color.rgb, in.color.a * alpha);
}

// ---------------------------
// Background Pass (Blocks with Rounded Corners & Borders)
// ---------------------------

struct RectInstance {
    float2 origin;
    float2 size;
    float4 color;
    float cornerRadius;
    float borderWidth;
    float4 borderColor;
    float padding;
};

struct RectVertexOut {
    float4 position [[position]];
    float2 localPos;      // Position within the rect (0 to size)
    float2 size;          // Size of the rect
    float4 color;         // Fill color
    float cornerRadius;   // Corner radius
    float borderWidth;    // Border width
    float4 borderColor;   // Border color
    float scale;          // Retina scale factor
};

// Signed distance function for rounded rectangle
float sdRoundedRect(float2 p, float2 halfSize, float radius) {
    float2 q = abs(p) - halfSize + radius;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius;
}

vertex RectVertexOut rect_vertex(const VertexIn vertexIn [[stage_in]],
                                  const device RectInstance* instances [[buffer(1)]],
                                  constant Uniforms& uniforms [[buffer(2)]],
                                  uint instanceID [[instance_id]]) {
    RectVertexOut out;
    RectInstance instance = instances[instanceID];

    float2 pixelPos = instance.origin + (vertexIn.position * instance.size);
    pixelPos.x -= uniforms.cameraX;
    pixelPos.y -= uniforms.cameraY;

    float x = (pixelPos.x / uniforms.viewportSize.x) * 2.0 - 1.0;
    float y = (1.0 - (pixelPos.y / uniforms.viewportSize.y) * 2.0);

    out.position = float4(x, y, 0.0, 1.0);
    out.localPos = vertexIn.position * instance.size;  // Local position within rect
    out.size = instance.size;
    out.color = instance.color;
    out.cornerRadius = instance.cornerRadius;
    out.borderWidth = instance.borderWidth;
    out.borderColor = instance.borderColor;
    out.scale = uniforms.scale;
    return out;
}

fragment float4 rect_fragment(RectVertexOut in [[stage_in]]) {
    // For simple rects (no corner radius), return fill color directly
    if (in.cornerRadius <= 0.0 && in.borderWidth <= 0.0) {
        return in.color;
    }

    // Calculate position relative to rect center
    float2 center = in.size * 0.5;
    float2 p = in.localPos - center;
    float2 halfSize = center;

    // Clamp corner radius to half of smallest dimension
    float radius = min(in.cornerRadius, min(halfSize.x, halfSize.y));

    // Calculate signed distance
    float d = sdRoundedRect(p, halfSize, radius);

    // Anti-aliasing width in logical points (0.5 physical pixels)
    // Using scale-aware AA ensures consistent rendering on retina displays
    float aa = 0.5 / in.scale;

    // If we have a border
    if (in.borderWidth > 0.0) {
        // Outside the shape - discard
        if (d > aa) {
            discard_fragment();
        }

        // Inside border region
        float innerD = d + in.borderWidth;

        if (innerD < -aa) {
            // Fully inside fill region
            return in.color;
        } else if (d < -aa) {
            // In border region (between inner and outer edge)
            return in.borderColor;
        } else {
            // On outer edge - anti-alias border
            float alpha = 1.0 - smoothstep(-aa, aa, d);
            return float4(in.borderColor.rgb, in.borderColor.a * alpha);
        }
    } else {
        // No border - just rounded fill
        if (d > aa) {
            discard_fragment();
        }

        // Anti-alias the edge
        float alpha = 1.0 - smoothstep(-aa, aa, d);
        return float4(in.color.rgb, in.color.a * alpha);
    }
}

// ---------------------------
// Phase 3: Compute Shader Culling
// ---------------------------

/// Line layout data for GPU-side culling
struct LineLayout {
    float yMin;
    float yMax;
};

/// Culling parameters
struct CullParams {
    float viewportTop;
    float viewportBottom;
    uint lineCount;
    uint padding;
};

/// Per-instance visibility result
struct VisibilityResult {
    uint visible;  // 1 if visible, 0 if culled
    uint lineIndex;
};

/// Compute shader for determining which instances are visible.
/// This moves the visibility check to the GPU for parallel processing.
/// Input: array of line layouts, viewport bounds
/// Output: array of visibility results (can be used for indirect draw)
kernel void compute_visibility(
    device const LineLayout* lineLayouts [[buffer(0)]],
    constant CullParams& params [[buffer(1)]],
    device VisibilityResult* results [[buffer(2)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= params.lineCount) return;

    LineLayout layout = lineLayouts[id];

    // Check if line overlaps with viewport (with some buffer for smooth scrolling)
    float buffer = 100.0; // Pixel buffer for smooth scrolling
    bool visible = (layout.yMax >= params.viewportTop - buffer) &&
                   (layout.yMin <= params.viewportBottom + buffer);

    results[id].visible = visible ? 1 : 0;
    results[id].lineIndex = id;
}

/// Compute shader for compacting visible instances.
/// Uses atomic counters for stream compaction.
kernel void compact_visible_instances(
    device const InstanceData* allInstances [[buffer(0)]],
    device const VisibilityResult* visibility [[buffer(1)]],
    device InstanceData* visibleInstances [[buffer(2)]],
    device atomic_uint* visibleCount [[buffer(3)]],
    uint id [[thread_position_in_grid]]
) {
    if (visibility[id].visible == 0) return;

    // Atomic increment to get output index
    uint outputIndex = atomic_fetch_add_explicit(visibleCount, 1, memory_order_relaxed);
    visibleInstances[outputIndex] = allInstances[id];
}

// ---------------------------
// Phase 3: Dual-Source Blending for Subpixel Rendering
// ---------------------------

/// Output for dual-source blending (subpixel anti-aliasing)
struct DualSourceOutput {
    float4 color [[color(0)]];
    float4 blend [[color(0), index(1)]];
};

/// Fragment shader with dual-source blending for subpixel LCD rendering.
/// This provides better text quality by using per-channel alpha.
///
/// Blend equation:
/// - Final.RGB = Fragment.RGB * Fragment.A + Dest.RGB * (1 - Blend.RGB)
/// - This allows independent alpha for R, G, B channels (subpixel AA)
fragment DualSourceOutput text_fragment_subpixel(
    VertexOut in [[stage_in]],
    texture2d<float> atlas [[texture(0)]]
) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);

    // Sample RGB subpixel coverage from atlas
    // For true subpixel rendering, the atlas would contain RGB coverage
    // Here we simulate with the R channel for each subpixel
    float2 texelSize = float2(1.0) / float2(atlas.get_width(), atlas.get_height());

    // Sample at subpixel offsets (1/3 pixel for LCD RGB stripe)
    float subpixelOffset = texelSize.x / 3.0;

    float coverageR = atlas.sample(s, in.uv + float2(-subpixelOffset, 0)).r;
    float coverageG = atlas.sample(s, in.uv).r;
    float coverageB = atlas.sample(s, in.uv + float2(subpixelOffset, 0)).r;

    // Apply gamma correction for LCD
    float3 coverage = float3(coverageR, coverageG, coverageB);
    coverage = pow(coverage, 1.0 / 1.8); // Slight gamma adjustment for LCD

    DualSourceOutput out;

    // Color output: text color with per-channel alpha
    out.color = float4(in.color.rgb * coverage, 1.0);

    // Blend factor: inverse coverage per channel
    out.blend = float4(coverage, 1.0);

    return out;
}

// ---------------------------
// Phase 4: Optimized Instance Buffer Generation
// ---------------------------

/// Structure for pre-computed glyph data (matches CPU GlyphInstance)
struct GlyphData {
    float2 uvMin;
    float2 uvMax;
    float2 size;
    float advance;
    float padding;
};

/// Compute shader for generating instance data from text and glyph lookup.
/// This moves instance buffer generation to the GPU for large text blocks.
kernel void generate_text_instances(
    device const uchar* textData [[buffer(0)]],      // UTF-8 text
    device const GlyphData* glyphLUT [[buffer(1)]],  // Glyph lookup table (256 entries for ASCII)
    device InstanceData* instances [[buffer(2)]],     // Output instances
    device atomic_uint* instanceCount [[buffer(3)]], // Output count
    constant float4& params [[buffer(4)]],           // x, y, lineHeight, monoAdvance
    uint id [[thread_position_in_grid]]
) {
    uchar ch = textData[id];

    // Skip whitespace (spaces and common invisible chars)
    if (ch == 0x20 || ch == 0x09 || ch == 0x0A || ch == 0x0D || ch == 0) {
        return;
    }

    // Clamp to ASCII range
    if (ch > 127) ch = '?';

    GlyphData glyph = glyphLUT[ch];

    // Calculate position (simplified - actual would need line tracking)
    float x = params.x + float(id) * params.w; // params.w = monoAdvance
    float y = params.y;

    // Create instance
    uint outputIdx = atomic_fetch_add_explicit(instanceCount, 1, memory_order_relaxed);

    instances[outputIdx].origin = float2(x, y);
    instances[outputIdx].size = glyph.size;
    instances[outputIdx].uvMin = glyph.uvMin;
    instances[outputIdx].uvMax = glyph.uvMax;
    instances[outputIdx].color = float4(1.0); // Default white, would be colored from style
}

// ---------------------------
// Diff Loader Shader (Bubbles & Waves & Boids)
// ---------------------------

struct DiffLoaderUniforms {
    float2 resolution;
    float time;
    float closingProgress;
    int numFish;
    int isDarkMode;  // 1 for dark mode, 0 for light mode
    int padding2;
    int padding3;
};

struct DiffLoaderVertexOut {
    float4 position [[position]];
    float2 uv;
};

struct FishParticle {
    float2 position;
    float2 velocity;
};

// --- Boids Compute Kernel ---

// Pseudo-random
float hash(float n) { return fract(sin(n) * 43758.5453123); }

kernel void update_fish(device FishParticle* particles [[buffer(0)]],
                        constant DiffLoaderUniforms& uniforms [[buffer(1)]],
                        uint id [[thread_position_in_grid]]) {

    int numFish = uniforms.numFish;
    if (id >= uint(numFish)) return;

    FishParticle p = particles[id];
    float2 pos = p.position;
    float2 vel = p.velocity;

    float2 separation = float2(0);
    float2 alignment = float2(0);
    float2 cohesion = float2(0);
    float2 center = float2(0); // Center of flock
    int count = 0;

    // Boids Parameters
    float r_sep = 0.1;
    float r_align = 0.3;
    float r_coh = 0.3;

    for (int i = 0; i < numFish; i++) {
        if (i == int(id)) continue;
        FishParticle other = particles[i];
        float d = distance(pos, other.position);

        if (d < r_sep) {
            // Separation: Steer away from neighbors
            separation += (pos - other.position) / (d + 0.0001);
        }
        if (d < r_align) {
            // Alignment: Match velocity
            alignment += other.velocity;

            // Cohesion: Calculate center of neighbors
            center += other.position;
            count++;
        }
    }

    if (count > 0) {
        alignment /= float(count);
        center /= float(count);
        // Cohesion: Steer towards center
        cohesion = center - pos;
    }

    // Normalize steering forces if they are significant
    if (length(alignment) > 0) alignment = normalize(alignment);
    if (length(cohesion) > 0) cohesion = normalize(cohesion);
    if (length(separation) > 0) separation = normalize(separation);

    // Weights
    float w_sep = 1.5;
    float w_align = 1.0;
    float w_coh = 0.8;

    // Solo / Darting Logic
    // Deterministic random per fish
    float randId = hash(float(id) * 0.123);
    bool isSolo = randId > 0.85; // 15% are solo swimmers

    if (isSolo) {
        w_sep = 2.0;
        w_align = 0.2; // Don't align much
        w_coh = 0.0;   // Don't cohere
    }

    // Apply forces
    float2 accel = separation * w_sep + alignment * w_align + cohesion * w_coh;

    // --- Procedural Noise / Turbulence ---
    // Simulating water currents or individual "free will"
    float time = uniforms.time;
    float noiseScale = 4.0;
    float nX = sin(pos.y * noiseScale + time + float(id)) * cos(pos.x * noiseScale + time * 0.5);
    float nY = cos(pos.x * noiseScale + time + float(id)) * sin(pos.y * noiseScale + time * 0.5);

    // Smoother swarm: reduce noise force (was 0.5)
    float noiseForce = 0.2;

    if (isSolo) {
        // Solo fish have erratic "darting" behavior
        // Use a time stepper to change direction suddenly
        float dartTimer = floor(time * 4.0 + randId * 10.0);
        float dartRand = hash(dartTimer);

        if (dartRand > 0.7) {
            // Dart!
            noiseForce = 4.0;
            // Change noise direction based on dartTimer
            nX = sin(dartTimer * 12.3);
            nY = cos(dartTimer * 45.6);
        } else {
            noiseForce = 0.5;
        }
    }

    accel += float2(nX, nY) * noiseForce;

    // --- Boundary Wrapping ---
    // Fish can only spawn/reset from sides or bottom, never from top
    float aspect = uniforms.resolution.x / uniforms.resolution.y;
    float margin = 0.1; // Margin outside the canonical -1..1 or -aspect..aspect box

    float xLimit = aspect + margin;
    float yLimit = 1.0 + margin;

    // If fish goes off any edge (except bottom), reset to bottom or side
    bool needsReset = false;
    if (pos.y > yLimit) needsReset = true;      // Off top
    if (pos.x < -xLimit) needsReset = true;     // Off left
    if (pos.x > xLimit) needsReset = true;      // Off right

    if (needsReset) {
        // Randomly choose to spawn from bottom (70%) or sides (30%)
        float spawnChoice = hash(float(id) + time * 0.1);

        if (spawnChoice < 0.7) {
            // Spawn from bottom
            pos.y = -yLimit - 0.5;
            pos.x = hash(float(id) + time) * (aspect * 1.6) - (aspect * 0.8);
            vel.x = (hash(float(id) * 2.0 + time) - 0.5) * 0.004;
            vel.y = abs(vel.y) * 0.5 + 0.002; // Ensure upward velocity
        } else {
            // Spawn from left or right side
            bool fromLeft = hash(float(id) * 3.0 + time) > 0.5;
            pos.x = fromLeft ? -xLimit - 0.3 : xLimit + 0.3;
            pos.y = hash(float(id) + time * 0.5) * 1.6 - 0.8; // Random Y in visible range
            vel.x = fromLeft ? 0.003 : -0.003; // Velocity towards center
            vel.y = 0.002; // Slight upward drift
        }
    }

    // Add a floor to prevent fish from swimming off the bottom
    if (pos.y < -yLimit) {
        pos.y = -yLimit; // Clamp position
        vel.y = abs(vel.y) * 0.5; // Turn around, reduce speed
    }


    // Update Velocity
    float dt = 0.016; // Approx 60fps
    vel += accel * dt;

    // Limit speed (Hydrodynamic drag limits)
    float speed = length(vel);
    float maxSpeed = 0.005; // Tuned for visual speed

    if (isSolo) {
        maxSpeed = 0.010; // Solo fish can go faster
    }

    float minSpeed = 0.005; // Keep them moving

    if (speed > maxSpeed) {
        vel = normalize(vel) * maxSpeed;
    } else if (speed < minSpeed && speed > 0.0001) {
        vel = normalize(vel) * minSpeed;
    }

    // Update Position
    pos += vel;

    // Add a constant upward drift to simulate camera descent
    pos.y += 0.012;

    // Write back
    particles[id].position = pos;
    particles[id].velocity = vel;
}


vertex DiffLoaderVertexOut diff_loader_vertex(const device float2* positions [[buffer(0)]],
                                              uint vid [[vertex_id]],
                                              constant DiffLoaderUniforms& uniforms [[buffer(1)]]) {
    DiffLoaderVertexOut out;
    float2 pos = positions[vid];
    out.position = float4(pos.x * 2.0 - 1.0, (1.0 - pos.y) * 2.0 - 1.0, 0.0, 1.0);

    float2 uv;
    uv.y = (1.0 - pos.y) * 2.0 - 1.0;
    uv.x = (pos.x * 2.0 - 1.0) * (uniforms.resolution.x / uniforms.resolution.y);

    out.uv = uv;

    return out;
}

// SDF Utilities
float smin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

float sdCircle(float2 p, float r) {
    return length(p) - r;
}

// Noise
float noise(float2 x) {
    float2 p = floor(x);
    float2 f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    float n = p.x + p.y * 57.0;
    return mix(mix(hash(n + 0.0), hash(n + 1.0), f.x),
               mix(hash(n + 57.0), hash(n + 58.0), f.x), f.y);
}

fragment float4 diff_loader_fragment(DiffLoaderVertexOut in [[stage_in]],
                                     constant DiffLoaderUniforms& uniforms [[buffer(0)]],
                                     device FishParticle* particles [[buffer(2)]]) {
    float2 uv = in.uv; // x: -aspect..aspect, y: -1..1
    float t = uniforms.time;

    // Adaptive colors based on dark/light mode
    bool isDarkMode = uniforms.isDarkMode == 1;

    // Dark mode colors
    float3 cDarkMode_Dark = float3(0.1, 0.1, 0.1);      // #1A1A1A - dark water
    float3 cDarkMode_Purple = float3(0.541, 0.459, 1.0); // #8A75FF - purple sky
    float3 cDarkMode_White = float3(1.0, 1.0, 1.0);      // #FFFFFF - white sun/elements

    // Light mode colors
    float3 cLightMode_Dark = float3(0.36, 0.38, 0.41);   // #5C6169 - darker water (ayu text color)
    float3 cLightMode_Purple = float3(0.85, 0.87, 0.93); // #D9DEF0 - light purple/gray sky
    float3 cLightMode_White = float3(0.48, 0.51, 0.55);  // #7B8289 - darker sun/elements

    // Select colors based on mode
    float3 cDark = isDarkMode ? cDarkMode_Dark : cLightMode_Dark;
    float3 cPurple = isDarkMode ? cDarkMode_Purple : cLightMode_Purple;
    float3 cWhite = isDarkMode ? cDarkMode_White : cLightMode_White;

    float aa = 0.005; // Anti-aliasing width
    float thickness = 0.005; // Line thickness

    // --- Time/Phase Logic ---
    // Accelerated Transition Plan:
    // Phase 1: Sun Rise (0 - 0.5s)
    // Phase 2: Waves Enter (0.5s - 1.0s)
    // Phase 3: Waves Bob (1.0s - 2.0s)
    // Phase 4: Descent (2.0s - 3.5s)
    // Phase 5: Deep Ocean (3.5s+)

    // --- Sun Animation ---
    // Start at bottom, rise to center, then move up with the water during descent
    float sunT = clamp(t * 2.0, 0.0, 1.0); // 0-0.5s mapped to 0-1
    float sunY = mix(-0.5, 0.3, smoothstep(0.0, 1.0, sunT)); // Initial rise
    if (t > 2.0) {
        // During descent, move the sun up and out of the screen
        float descentProgress = smoothstep(2.0, 3.5, t);
        sunY = mix(0.3, 1.5, descentProgress); // Move from resting pos to offscreen
    }
    float dSun = sdCircle(uv - float2(0.0, sunY), 0.12);
    float sunAlpha = 1.0 - smoothstep(0.0, aa, dSun);

    // --- Water Level / Camera Descent ---
    float waterBaseLevel = -1.5; // Starts below screen

    if (t > 0.5 && t <= 1.0) {
        // Ease out cubic
        float p = (t - 0.5) * 2.0; // 0..1
        float ease = 1.0 - pow(1.0 - p, 3.0);
        waterBaseLevel = mix(-1.5, -0.2, ease); // Rise to slightly below center
    } else if (t > 1.0 && t <= 2.0) {
        waterBaseLevel = -0.2;
    } else if (t > 2.0) {
        // Descent: Water covers everything.
        waterBaseLevel = mix(-0.2, 2.0, smoothstep(2.0, 3.5, t)); // Accelerated descent
    }

    // Wave Offset
    float waveOffset = 0.0;
    float waveLineAlpha = 0.0;

    // Calculate Wave
    float waveH = 0.0;
    for(int i=0; i<3; i++) {
        float fi = float(i);
        float speed = 2.5 + fi * 0.8;
        float freq = 2.0 + fi * 1.0;
        float amp = 0.18 + 0.03 * sin(t * 0.5 + fi);
        waveH += amp * sin(uv.x * freq + t * speed + fi * 2.0);
    }

    // Actual water surface Y at this x
    float surfaceY = waterBaseLevel + waveH;

    // Determine Background Color
    float3 bgColor = cPurple;
    bool isUnderwater = uv.y < surfaceY;

    if (isUnderwater) {
        bgColor = cDark;
    }

    // Draw Sun (Only in Sky)
    float3 color = mix(bgColor, cWhite, sunAlpha * (isUnderwater ? 0.0 : 1.0));

    // Wave Line (Purple highlight at the boundary)
    float dWave = abs(uv.y - surfaceY);
    float waveStroke = 1.0 - smoothstep(thickness, thickness + aa, dWave);

    // 1. Sky
    color = cPurple;

    // 2. Sun (in Sky)
    color = mix(color, cWhite, sunAlpha);

    // 3. Water (Dark)
    float waterMask = 1.0 - smoothstep(0.0, aa, uv.y - surfaceY); // 1 if below surface
    color = mix(color, cDark, waterMask);

    // 4. Wave Highlight Line
    color = mix(color, cPurple, waveStroke);

    // --- Deep Ocean Life (Bubbles & Creatures) ---

    // --- Bubbles ---
    float bubbleDist = 100.0;
    float bubblesAlpha = 0.0;

    // Start emitting bubbles only after fully submerged (Phase 5).
    if (t > 3.5) {
        int numBubbles = int(min(80.0, (t - 3.5) * 20.0));
        float descentSpeed = 0.6; // Faster descent speed

        // Early exit threshold - max bubble size + smoothing radius
        float cullRadius = 0.15 + 0.15;

        for (int i = 0; i < numBubbles; i++) {
            float fi = float(i);
            float randX = hash(fi * 1.23) * 1.6 - 0.8; // Range: -0.8 to 0.8
            float randSpeed = 0.8 + hash(fi * 4.56) * 0.4;

            float cycleLen = 10.0;
            float t_offset = fi * 1.5;
            float localT = fmod(t + t_offset, cycleLen);

            float riseY = -1.5 + localT * (randSpeed + descentSpeed);

            // Quick Y-based culling before expensive calculations
            float yDist = abs(uv.y - riseY);
            if (yDist > cullRadius) continue;

            float randPhase = hash(fi * 7.89) * 6.28;
            float wobbleX = sin(t * 2.0 + randPhase) * 0.05;
            float2 bubblePos = float2(randX + wobbleX, riseY);

            // Quick distance check before size calculation
            float quickDist = length(uv - bubblePos);
            if (quickDist > cullRadius) continue;

            float size = 0.01 + hash(fi * 10.11) * 0.06;

            // Calculate emission time: absolute time when this specific bubble instance started its current cycle
            float emissionTime = (t + t_offset) - localT;

            // Randomize Emission (Spurting)
            // Determine "spurtiness" based on emissionTime so it's constant for the bubble's lifetime
            float spurtNoise = noise(float2(emissionTime * 0.1, 0.0));

            // Create gaps:
            if (spurtNoise < 0.4) {
                continue; // Skip this bubble entirely
            } else if (spurtNoise > 0.7) {
                size *= 1.5; // Bigger bubbles in clumps
            }

            float d = quickDist - size;
            bubbleDist = smin(bubbleDist, d, 0.15);
        }

        float bubbleOutline = abs(bubbleDist) - thickness;
        bubblesAlpha = 1.0 - smoothstep(0.0, aa, bubbleOutline);
    }

    color = mix(color, cWhite, bubblesAlpha);

    // --- Aquatic Life (Boids) ---
    // Swarming fish with trails
    // Only visible in Water
    if (t > 2.5) {
        float lifeFadeIn = smoothstep(2.5, 4.0, t);
        int numFish = uniforms.numFish;

        // Culling radius: max trail length + body radius
        float cullRadius = 0.5 + 0.02 + 0.013;

        // Loop through simulated particles
        for (int j = 0; j < numFish; j++) {
            FishParticle p = particles[j];
            float2 p_now = p.position;

            // Early distance culling - skip fish far from this pixel
            float2 toFish = uv - p_now;
            float distSq = dot(toFish, toFish);
            if (distSq > cullRadius * cullRadius) continue;

            float2 vel = p.velocity;
            float velLen = length(vel);
            float speed = velLen * 60.0; // Approx normalized speed (assuming 60fps, vel is per frame)

            // Direction for orientation
            float2 dir = (velLen > 0.0001) ? vel / velLen : float2(0.0, 1.0);

            float bodyRadius = 0.013;

            // Trail (SDF Motion Blur)
            float speedThreshold = 0.4; // Tuned
            float trailAlpha = 0.0;

            if (speed > speedThreshold) {
                float maxTrail = 0.5;
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

            // Body SDF
            float bodyLen = 0.02;
            float2 bodyTail = p_now - dir * bodyLen;

            float2 pa_b = toFish;
            float2 ba_b = bodyTail - p_now;
            float baDotBa_b = dot(ba_b, ba_b);
            float h_b = (baDotBa_b > 0.0001) ? clamp(dot(pa_b, ba_b) / baDotBa_b, 0.0, 1.0) : 0.0;
            float dBody = length(pa_b - ba_b * h_b) - bodyRadius;

            float bodyAlpha = 1.0 - smoothstep(0.0, aa, dBody);

            color = mix(color, cPurple * 0.6, trailAlpha * 0.6 * lifeFadeIn);
            color = mix(color, cPurple, bodyAlpha * lifeFadeIn);
        }
    }

    // --- Closing Animation ---
    if (uniforms.closingProgress > 0.0) {
        float maxRadius = 2.0;
        float p = uniforms.closingProgress;
        float ease = 1.0 - pow(1.0 - p, 3.0);
        float currentRadius = maxRadius * (1.0 - ease);

        float dMask = length(uv) - currentRadius;
        float maskAlpha = smoothstep(0.0, aa, dMask);

        color = mix(color, float3(0.0), maskAlpha);
    }

    return float4(color, 1.0);
}
