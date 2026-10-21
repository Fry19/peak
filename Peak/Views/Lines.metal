#include <metal_stdlib>
using namespace metal;

// One line segment of the overlay, in points. Must match `LineSegment` in LineRenderer.swift.
struct LineSegment {
    float2 a;
    float2 b;
    float4 color;      // straight (not premultiplied) color; alpha is the line's opacity
    float width;       // the line's width
    float glow;        // how far the glow spreads around it
    float glowAlpha;   // the glow's opacity at the line
    float pad;
};

struct Uniforms {
    float2 viewport;   // view size in points
    float scale;       // pixels per point
    float pad;
};

struct VertexOut {
    float4 position [[position]];
    float2 p;
    float2 a [[flat]];
    float2 b [[flat]];
    float4 color [[flat]];
    float halfWidth [[flat]];
    float glow [[flat]];
    float glowAlpha [[flat]];
};

// Each segment is drawn as a quad around it, wide enough for the line and its glow
// (four vertices of a triangle strip, one instance per segment).
vertex VertexOut lineVertex(uint vid [[vertex_id]],
                            uint iid [[instance_id]],
                            const device LineSegment *segments [[buffer(0)]],
                            constant Uniforms &u [[buffer(1)]]) {
    LineSegment s = segments[iid];
    float2 d = s.b - s.a;
    float len = length(d);
    float2 dir = len > 1e-4 ? d / len : float2(1.0, 0.0);
    float2 normal = float2(-dir.y, dir.x);
    float reach = s.width * 0.5 + s.glow * 1.5 + 2.0 / u.scale;
    float2 end = vid < 2 ? s.a - dir * reach : s.b + dir * reach;
    float2 p = end + normal * (vid % 2 == 0 ? -reach : reach);

    VertexOut out;
    out.position = float4(p.x / u.viewport.x * 2.0 - 1.0, 1.0 - p.y / u.viewport.y * 2.0, 0.0, 1.0);
    out.p = p;
    out.a = s.a;
    out.b = s.b;
    out.color = s.color;
    out.halfWidth = s.width * 0.5;
    out.glow = s.glow;
    out.glowAlpha = s.glowAlpha;
    return out;
}

// The line itself, antialiased over about a pixel, with a soft glow falling off around it.
// Blending takes the brighter of overlapping quads, so joins don't double up.
fragment float4 lineFragment(VertexOut in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
    float2 pa = in.p - in.a;
    float2 ba = in.b - in.a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
    float dist = length(pa - ba * h);
    float core = clamp((in.halfWidth - dist) * u.scale + 0.5, 0.0, 1.0) * in.color.a;
    float sigma = max(in.glow * 0.5, 1e-3);
    float glow = in.glow > 0.0 ? in.glowAlpha * exp(-(dist * dist) / (2.0 * sigma * sigma)) : 0.0;
    float alpha = max(core, glow);
    return float4(in.color.rgb * alpha, alpha);
}
