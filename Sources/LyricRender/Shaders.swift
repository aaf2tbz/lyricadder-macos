// Metal Shading Language source for the karaoke renderer.
// Kept as a string and compiled with MTLDevice.makeLibrary(source:) so the package builds with plain
// `swift build` and the .app needs no SwiftPM resource bundle. `lyricadder-cli check-shaders` and the
// build script also compile it with the offline `metal` compiler to catch errors at build time.

let karaokeShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Globals {
    float2 viewport;   // drawable size in pixels
    float  time;       // song time in seconds (for subtle animation)
    float  pad;
};

// Must match `QuadInstance` in KaraokeRenderer.swift (5 x float4 = 80 bytes).
struct Quad {
    float4 rect;    // x, y, w, h in pixels, origin top-left
    float4 color;   // base color (straight alpha)
    float4 color2;  // highlight / second gradient color
    float4 p0;      // x: wipe position in quad pixels, y: corner radius px, z: mode, w: opacity
    float4 p1;      // x: wipe edge softness px, y: glow strength, z: glow mip bias, w: unused
};

struct VOut {
    float4 position [[position]];
    float2 local;           // pixel position inside the quad
    float2 uv;
    uint   inst [[flat]];
};

constant float2 kCorners[6] = { {0,0}, {1,0}, {0,1}, {1,0}, {1,1}, {0,1} };

vertex VOut quad_vertex(uint vid [[vertex_id]],
                        uint iid [[instance_id]],
                        constant Globals &g [[buffer(0)]],
                        const device Quad *quads [[buffer(1)]])
{
    Quad q = quads[iid];
    float2 c = kCorners[vid];
    float2 px = q.rect.xy + c * q.rect.zw;
    VOut o;
    o.position = float4(px.x / g.viewport.x * 2.0 - 1.0, 1.0 - px.y / g.viewport.y * 2.0, 0.0, 1.0);
    o.local = c * q.rect.zw;
    o.uv = c;
    o.inst = iid;
    return o;
}

fragment float4 quad_fragment(VOut in [[stage_in]],
                              constant Globals &g [[buffer(0)]],
                              const device Quad *quads [[buffer(1)]],
                              texture2d<float> tex [[texture(0)]],
                              sampler smp [[sampler(0)]])
{
    Quad q = quads[in.inst];
    int mode = int(q.p0.z + 0.5);
    float3 rgb;
    float a;

    if (mode == 1) {
        // Text: coverage from the glyph texture, karaoke wipe between base and highlight color.
        float cov = tex.sample(smp, in.uv).r;
        float wipe = q.p0.x;
        float soft = max(q.p1.x, 0.5);
        float sung = 1.0 - smoothstep(wipe - soft, wipe + soft, in.local.x);
        rgb = mix(q.color.rgb, q.color2.rgb, sung);
        a = cov * mix(q.color.a, q.color2.a, sung);
        float3 prem = rgb * a;
        if (q.p1.y > 0.0) {
            // Cheap bloom on the sung part: sample a blurrier mip level of the same glyph texture.
            float halo = tex.sample(smp, in.uv, bias(q.p1.z)).r;
            float ga = saturate(halo * 1.6) * q.p1.y * sung;
            prem = prem + q.color2.rgb * ga * (1.0 - a);
            a = a + ga * (1.0 - a);
        }
        a *= q.p0.w;
        return float4(prem * q.p0.w, a);
    } else if (mode == 2) {
        // Background: vertical gradient plus a slow, soft light near the lyric line.
        float t = in.uv.y;
        rgb = mix(q.color.rgb, q.color2.rgb, t);
        float2 p = in.uv - float2(0.5, 0.42);
        p.x *= g.viewport.x / max(g.viewport.y, 1.0);
        float pulse = 0.85 + 0.15 * sin(g.time * 0.8);
        rgb += float3(0.10, 0.05, 0.02) * exp(-dot(p, p) * 5.0) * pulse;
        // A little dithering to stop gradient banding.
        float n = fract(sin(dot(in.position.xy, float2(12.9898, 78.233))) * 43758.5453);
        rgb += (n - 0.5) / 255.0;
        a = 1.0;
    } else {
        // Rounded rectangle via signed distance.
        float2 halfSize = q.rect.zw * 0.5;
        float r = min(q.p0.y, min(halfSize.x, halfSize.y));
        float2 d = abs(in.local - halfSize) - (halfSize - r);
        float dist = length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - r;
        a = q.color.a * (1.0 - smoothstep(-0.75, 0.75, dist));
        rgb = q.color.rgb;
    }
    a *= q.p0.w;
    return float4(rgb * a, a);
}
"""
