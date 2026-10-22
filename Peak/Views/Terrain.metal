#include <metal_stdlib>
using namespace metal;

// How the terrain seen from above is drawn. Must match `TerrainUniforms` in LineRenderer.swift.
struct TerrainUniforms {
    float4 right;     // the camera's axes, east-north-up (Camera.Projector)
    float4 down;
    float4 forward;
    float4 eye;       // xyz: the eye, meters from the mesh's center; w: where the terrain ends
    float4 lens;      // fx, fy, cx, cy, in points
    float4 view;      // width, height in points; the near plane
    float4 haze;      // x: the distance haze covers two thirds of the ground over at the height
                      // of the ground under the eye; y: the height over which it thins by e, meters
    float4 sky;       // the night sky high up; a: opacity
    float4 horizon;   // the paler sky along the horizon, which haze takes; a: the sine of the
                      // elevation by which the sky has turned to `sky`
    float4 dark;      // ground facing away from the light
    float4 light;     // ground facing the light
};

// The sky's color in a direction `s` (sine of its elevation) from the eye: the horizon's
// tone level and below, deepening to the night sky above.
static float3 skyColor(float s, constant TerrainUniforms &u) {
    return mix(u.horizon.rgb, u.sky.rgb, smoothstep(0.0, u.horizon.a, s));
}

struct TerrainOut {
    float4 position [[position]];
    float shade;
    float3 ray;       // from the eye, east-north-up meters
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
    out.ray = p;
    out.ground = length(v.xy);
    return out;
}

// How much haze lies between the eye and a point `ray` (`range` meters) from it: haze is
// thicker low down, thinning with height above the ground under the eye (where the eye is
// `u.eye.z` up), so valleys fill with it and the ridges in front of them stand clear.
static float hazeAlong(float3 ray, float range, constant TerrainUniforms &u) {
    float k = 1.0 / u.haze.y;
    float dz = ray.z * k;
    // The haze's mean density along the ray, from the eye's height to the point's; at most
    // three times as thick as at the ground under the eye, looking far down.
    float mean = exp(-u.eye.z * k) * (abs(dz) > 1e-3 ? (1.0 - exp(-dz)) / dz : 1.0 - dz * 0.5);
    return 1.0 - exp(-range / u.haze.x * min(mean, 3.0));
}

// Slopes lit by their shade, paler and bluer with distance like haze: toward the sky behind
// them, which near the horizon is paler than the ground, so each ridge stands out against
// the hazier one beyond. Into it entirely before the terrain ends, so its edge doesn't show
// as a skyline.
fragment float4 terrainFragment(TerrainOut in [[stage_in]], constant TerrainUniforms &u [[buffer(1)]]) {
    float3 ground = mix(u.dark.rgb, u.light.rgb, in.shade);
    float range = length(in.ray);
    float haze = hazeAlong(in.ray, range, u);
    float edge = smoothstep(u.eye.w * 0.8, u.eye.w, in.ground);
    float3 color = mix(ground, skyColor(in.ray.z / range, u), max(haze, edge));
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
// in behind them), so the lines and their halos look as they do over the camera; where
// there's no terrain, the sky, as the haze has it. Premultiplied: the terrain's alpha is
// already the opacity.
fragment float4 compositeFragment(CompositeOut in [[stage_in]], texture2d<float> terrain [[texture(0)]],
                                  constant TerrainUniforms &u [[buffer(1)]]) {
    float4 t = terrain.read(uint2(in.position.xy));
    // The ray through this pixel, from the lens, which is in points.
    float2 p = in.position.xy * u.view.xy / float2(terrain.get_width(), terrain.get_height());
    float3 ray = u.forward.xyz + u.right.xyz * ((p.x - u.lens.z) / u.lens.x) + u.down.xyz * ((p.y - u.lens.w) / u.lens.y);
    float3 sky = skyColor(normalize(ray).z, u);
    return float4(t.rgb + sky * (u.sky.a - t.a), u.sky.a);
}
