/// Compiled at runtime because `swift build` does not compile `.metal` files.
let shaderSource = """
#include <metal_stdlib>
using namespace metal;

constant float3 kLuma = float3(0.299, 0.587, 0.114);

struct BlendUniforms {
    float staticWeight;
    float motionLow;
    float motionHigh;
    float resetThreshold;
    uint reset;
    uint pixelCount;
};

struct GuidedUniforms {
    int radius;
    float epsilon;
    float maxCoefficient;
};

struct CompositeUniforms {
    float2 cameraOrigin;
    float2 cameraScale;
    float2 outputSize;
    float detail;
    float feather;
    uint guided;
    uint preserveColors;
    uint maskMode;
    uint hasMask;
    uint passthrough;
};

static inline float luma(float3 c) { return dot(c, kLuma); }

static inline uint2 clamped(uint2 gid, int2 offset, int2 size) {
    return uint2(clamp(int2(gid) + offset, int2(0), size - 1));
}

// Writes current luma and the 3x3 mean absolute luma change against the previous frame, and adds the change to a
// frame-wide sum used to detect cuts.
kernel void motion_luma(texture2d<float, access::read> input [[texture(0)]],
                        texture2d<float, access::read> previousLuma [[texture(1)]],
                        texture2d<float, access::write> currentLuma [[texture(2)]],
                        texture2d<float, access::write> motion [[texture(3)]],
                        device atomic_uint *motionSum [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]])
{
    int2 size = int2(input.get_width(), input.get_height());
    float change = 0.0;
    if (int(gid.x) < size.x && int(gid.y) < size.y) {
        currentLuma.write(float4(luma(input.read(gid).rgb)), gid);
        for (int dy = -1; dy <= 1; dy++) {
            for (int dx = -1; dx <= 1; dx++) {
                uint2 p = clamped(gid, int2(dx, dy), size);
                change += abs(luma(input.read(p).rgb) - previousLuma.read(p).r);
            }
        }
        change = min(change / 9.0, 1.0);
        motion.write(float4(change), gid);
    }
    float groupChange = simd_sum(change);
    if (simd_is_first()) {
        atomic_fetch_add_explicit(motionSum, uint(groupChange * 1024.0), memory_order_relaxed);
    }
}

// The motion gate takes the largest change in a 13x13 window: the 3x3 change only fires on moving edges, and
// low-texture moving skin next to them would otherwise be blended with the previous frame and smear.
kernel void temporal_blend(texture2d<float, access::read> stylized [[texture(0)]],
                           texture2d<float, access::read> previous [[texture(1)]],
                           texture2d<float, access::read> motion [[texture(2)]],
                           texture2d<float, access::write> smoothed [[texture(3)]],
                           constant BlendUniforms &u [[buffer(0)]],
                           device const uint *motionSum [[buffer(1)]],
                           uint2 gid [[thread_position_in_grid]])
{
    int2 size = int2(stylized.get_width(), stylized.get_height());
    if (int(gid.x) >= size.x || int(gid.y) >= size.y) return;
    float4 current = stylized.read(gid);
    float globalChange = float(motionSum[0]) / (1024.0 * float(u.pixelCount));
    if (u.reset != 0 || u.staticWeight >= 1.0 || globalChange > u.resetThreshold) {
        smoothed.write(current, gid);
        return;
    }
    float change = 0.0;
    for (int dy = -6; dy <= 6; dy += 3) {
        for (int dx = -6; dx <= 6; dx += 3) {
            change = max(change, motion.read(clamped(gid, int2(dx, dy), size)).r);
        }
    }
    float alpha = mix(u.staticWeight, 1.0, smoothstep(u.motionLow, u.motionHigh, change));
    smoothed.write(mix(previous.read(gid), current, alpha), gid);
}

// Fast guided filter coefficients (He & Sun 2015) at model resolution: a = cov(I, p) / (var(I) + eps) per channel,
// with the camera luma as the guide I and the stylized frame as p.
kernel void guided_coefficients(texture2d<float, access::read> guide [[texture(0)]],
                                texture2d<float, access::read> source [[texture(1)]],
                                texture2d<float, access::write> coefficients [[texture(2)]],
                                constant GuidedUniforms &u [[buffer(0)]],
                                uint2 gid [[thread_position_in_grid]])
{
    int2 size = int2(guide.get_width(), guide.get_height());
    if (int(gid.x) >= size.x || int(gid.y) >= size.y) return;
    float sumI = 0.0, sumII = 0.0;
    float3 sumP = 0.0, sumIP = 0.0;
    for (int dy = -u.radius; dy <= u.radius; dy++) {
        for (int dx = -u.radius; dx <= u.radius; dx++) {
            uint2 p = clamped(gid, int2(dx, dy), size);
            float i = guide.read(p).r;
            float3 v = source.read(p).rgb;
            sumI += i;
            sumII += i * i;
            sumP += v;
            sumIP += i * v;
        }
    }
    float n = float((2 * u.radius + 1) * (2 * u.radius + 1));
    float meanI = sumI / n;
    float3 meanP = sumP / n;
    float variance = max(sumII / n - meanI * meanI, 0.0);
    float3 covariance = sumIP / n - meanI * meanP;
    float3 a = clamp(covariance / (variance + u.epsilon), -u.maxCoefficient, u.maxCoefficient);
    coefficients.write(float4(a, 1.0), gid);
}

kernel void box_filter(texture2d<float, access::read> source [[texture(0)]],
                       texture2d<float, access::write> destination [[texture(1)]],
                       constant GuidedUniforms &u [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]])
{
    int2 size = int2(source.get_width(), source.get_height());
    if (int(gid.x) >= size.x || int(gid.y) >= size.y) return;
    float4 sum = 0.0;
    for (int dy = -u.radius; dy <= u.radius; dy++) {
        for (int dx = -u.radius; dx <= u.radius; dx++) {
            sum += source.read(clamped(gid, int2(dx, dy), size));
        }
    }
    destination.write(sum / float((2 * u.radius + 1) * (2 * u.radius + 1)), gid);
}

static inline float videoLuma(float3 rgb) {
    return (16.0 + 219.0 * saturate(luma(rgb))) / 255.0;
}

static inline float2 videoChroma(float3 rgb) {
    float cb = 128.0 + 224.0 * dot(rgb, float3(-0.168736, -0.331264, 0.5));
    float cr = 128.0 + 224.0 * dot(rgb, float3(0.5, -0.418688, -0.081312));
    return clamp(float2(cb, cr), 16.0, 240.0) / 255.0;
}

static inline float featheredMask(texture2d<float> mask, sampler s, float2 uv, float2 step) {
    float m = 0.0;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            m += mask.sample(s, uv + float2(dx, dy) * step).r;
        }
    }
    return m / 9.0;
}

static inline float3 compositePixel(uint2 pixel,
                                    texture2d<float> camera, texture2d<float> smoothed, texture2d<float> guideLow,
                                    texture2d<float> coefficients, texture2d<float> mask, texture2d<float> cameraTone,
                                    texture2d<float> styledTone, constant CompositeUniforms &u)
{
    constexpr sampler linear(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(pixel) + 0.5) / u.outputSize;
    float3 cam = camera.sample(linear, u.cameraOrigin + uv * u.cameraScale).rgb;
    // Masked modes show the camera until the first mask arrives.
    if (u.passthrough != 0 || (u.maskMode != 0 && u.hasMask == 0)) return cam;
    float3 styled = smoothed.sample(linear, uv).rgb;
    if (u.guided != 0) {
        float3 a = coefficients.sample(linear, uv).rgb;
        styled += u.detail * a * (luma(cam) - guideLow.sample(linear, uv).r);
    }
    styled = saturate(styled);
    if (u.preserveColors != 0) {
        // The stylized strokes over the camera's local mean luma, so faces keep their brightness. Adding the same
        // amount to every channel keeps the camera's chroma exactly.
        float tone = cameraTone.sample(linear, uv).r - luma(styledTone.sample(linear, uv).rgb);
        styled = cam + (luma(styled) + tone - luma(cam));
    }
    if (u.maskMode == 0) return styled;
    float person = featheredMask(mask, linear, uv, u.feather / u.outputSize);
    return mix(cam, styled, u.maskMode == 1 ? 1.0 - person : person);
}

// Upsamples, composites, and writes NV12 (BT.601 video range). Each thread writes a 2x2 block of luma and one
// chroma sample, sited left (co-sited with the even column, between the two rows) as H.264 and most consumers
// assume, so it takes a [1 2 1] filter over the columns next to the block.
kernel void composite_nv12(texture2d<float> camera [[texture(0)]],
                           texture2d<float> smoothed [[texture(1)]],
                           texture2d<float> guideLow [[texture(2)]],
                           texture2d<float> coefficients [[texture(3)]],
                           texture2d<float> mask [[texture(4)]],
                           texture2d<float, access::write> lumaPlane [[texture(5)]],
                           texture2d<float, access::write> chromaPlane [[texture(6)]],
                           texture2d<float> cameraTone [[texture(7)]],
                           texture2d<float> styledTone [[texture(8)]],
                           constant CompositeUniforms &u [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= chromaPlane.get_width() || gid.y >= chromaPlane.get_height()) return;
    float3 chroma = 0.0;
    for (uint row = 0; row < 2; row++) {
        uint2 pixel = uint2(gid.x * 2, gid.y * 2 + row);
        float3 left = compositePixel(uint2(max(int(pixel.x) - 1, 0), pixel.y), camera, smoothed, guideLow, coefficients,
                                     mask, cameraTone, styledTone, u);
        float3 center = compositePixel(pixel, camera, smoothed, guideLow, coefficients, mask, cameraTone, styledTone, u);
        float3 right = compositePixel(pixel + uint2(1, 0), camera, smoothed, guideLow, coefficients, mask, cameraTone,
                                      styledTone, u);
        lumaPlane.write(float4(videoLuma(center)), pixel);
        lumaPlane.write(float4(videoLuma(right)), pixel + uint2(1, 0));
        chroma += 0.25 * left + 0.5 * center + 0.25 * right;
    }
    chromaPlane.write(float4(videoChroma(chroma * 0.5), 0.0, 0.0), gid);
}
"""
