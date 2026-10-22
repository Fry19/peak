#include <metal_stdlib>
using namespace metal;

// How the terrain seen from above is drawn. Must match `TerrainUniforms` in LineRenderer.swift.
struct TerrainUniforms {
    float4 right;     // the camera's axes, east-north-up (Camera.Projector)
    float4 down;
    float4 forward;
    float4 eye;       // xyz: the eye, meters from the mesh's center; w: where the terrain ends
    float4 lens;      // fx, fy, cx, cy, in points
    float4 view;      // width, height in points; the near plane and the haze distance, meters
    float4 sky;       // the sky's color, which far terrain fades into; a: opacity
    float4 dark;      // ground facing away from the light
    float4 light;     // ground facing the light
};

struct TerrainOut {
    float4 position [[position]];
    float shade;
    float range;      // from the eye, meters
    float ground;     // from the mesh's center along the ground, meters
};

// Each vertex is projected by the overlay's own pinhole (Camera.Projector) in points, then to
// clip space with w = z, so the labels and lines drawn over it land on it. Depth is reversed
// (near / z) for precision tens of kilometers away.
vertex TerrainOut terrainVertex(uint vid [[vertex_id]],
                                const device float4 *vertices [[buffer(0)]],
                                constant TerrainUniforms &u [[buffer(1)]]) {
    float4 v = vertices[vid];
    float3 p = v.xyz - u.eye.xyz;
    float x = dot(p, u.right.xyz), y = dot(p, u.down.xyz), z = dot(p, u.forward.xyz);
    float px = u.lens.z * z + u.lens.x * x;   // (cx + fx x / z) · z
    float py = u.lens.w * z + u.lens.y * y;
    TerrainOut out;
    out.position = float4(px / u.view.x * 2.0 - z, z - py / u.view.y * 2.0, u.view.z, z);
    out.shade = v.w;
    out.range = length(p);
    out.ground = length(v.xy);
    return out;
}

// Slopes lit by their shade, fading into the sky with distance like haze, and into it
// entirely before the terrain ends, so its edge doesn't show as a skyline.
fragment float4 terrainFragment(TerrainOut in [[stage_in]], constant TerrainUniforms &u [[buffer(1)]]) {
    float3 ground = mix(u.dark.rgb, u.light.rgb, in.shade);
    float haze = 1.0 - exp(-in.range / u.view.w);
    float edge = smoothstep(u.eye.w * 0.8, u.eye.w, in.ground);
    float3 color = mix(ground, u.sky.rgb, max(haze, edge));
    return float4(color * u.sky.a, u.sky.a);
}

struct CompositeOut {
    float4 position [[position]];
};

// One triangle over the whole view.
vertex CompositeOut compositeVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    CompositeOut out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return out;
}

// The terrain, drawn on its own, laid under the lines already drawn (LineRenderer blends it
// in behind them), so the lines and their halos look as they do over the camera.
fragment float4 compositeFragment(CompositeOut in [[stage_in]], texture2d<float> terrain [[texture(0)]]) {
    return terrain.read(uint2(in.position.xy));
}
