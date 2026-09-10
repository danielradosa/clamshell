import Foundation

/// Metal Shading Language source, compiled at runtime.
///
/// Runtime compilation is not a stylistic choice: the offline `metal` compiler
/// ships with Xcode, and this project is built with the Command Line Tools
/// alone. `MTLDevice.makeLibrary(source:)` is handled entirely by the Metal
/// runtime, so the full pipeline works with no Xcode installed.
enum Shaders {

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct FoldUniforms {
        float fold;          // 0 = flat and untouched, 1 = fully folded away
        float perspective;   // strength of the depth foreshortening
        float darkening;     // how far toward black at full fold
        float shadowStrength;// opacity of the shadow gathering at the hinge
        float sheen;         // strength of the light sweeping across the panel
        float curvature;     // how much the panel bows out of plane
        float blurMix;       // 0 = fully sharp, 1 = fully blurred
        float blurLOD;       // mip level to read the blurred copy from
        float aspect;        // width / height, to keep the sheen circular
    };

    struct BlurUniforms {
        float2 texelStep;    // direction and size of one blur step, in UV
        float  radius;       // blur radius in texels
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
        float  depth;        // 0 at the hinge, 1 at the far edge, after folding
        float  shade;        // per-vertex lighting term
    };

    // ---------------------------------------------------------------------
    // Fullscreen triangle, used by both blur passes.
    // ---------------------------------------------------------------------
    struct FSOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex FSOut fullscreenVertex(uint vid [[vertex_id]]) {
        // One oversized triangle covers the viewport with no vertex buffer.
        float2 uv = float2((vid << 1) & 2, vid & 2);
        FSOut out;
        out.uv = uv;
        out.position = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
        return out;
    }

    // Nine-tap gaussian along one axis. Run twice, once per axis, for a
    // separable blur that costs 18 taps instead of the 81 a single pass needs.
    fragment float4 blurFragment(FSOut in [[stage_in]],
                                 texture2d<float> src [[texture(0)]],
                                 constant BlurUniforms &u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);

        const float weights[5] = { 0.2270270270, 0.1945945946, 0.1216216216,
                                   0.0540540541, 0.0162162162 };
        // Offsets chosen so linear filtering fetches two texels per tap.
        const float offsets[5] = { 0.0, 1.4615384615, 3.2307692308,
                                   5.0000000000, 6.7692307692 };

        float4 sum = src.sample(s, in.uv) * weights[0];
        for (int i = 1; i < 5; ++i) {
            float2 delta = u.texelStep * offsets[i] * u.radius;
            sum += src.sample(s, in.uv + delta) * weights[i];
            sum += src.sample(s, in.uv - delta) * weights[i];
        }
        return sum;
    }

    // ---------------------------------------------------------------------
    // The fold itself.
    // ---------------------------------------------------------------------
    //
    // The panel always covers the whole screen. This is the part that is easy to
    // get wrong: the obvious reading of "fold the desktop away" is to rotate the
    // image into the distance, which leaves it as a shrinking trapezoid on a
    // black field. That double-counts the perspective. The lid is *physically*
    // tilting away from the viewer already, and the eye reads that tilt from the
    // real object. Tilting the image as well shrinks the picture away from the
    // very softening it is supposed to be showing, and replaces most of the
    // screen with black.
    //
    // So the geometry here is deliberately restrained: a slight keystone, the
    // top edge drawn in a little as though the sheet were leaning back, plus a
    // gentle bow. Everything is then scaled so the quad still reaches all four
    // edges and no background is ever visible. Blur carries the effect.
    vertex VertexOut foldVertex(uint vid [[vertex_id]],
                                constant float2 *grid [[buffer(0)]],
                                constant FoldUniforms &u [[buffer(1)]]) {
        float2 p = grid[vid];              // x, y each in [-1, 1]
        float2 uv = float2((p.x + 1.0) * 0.5, 1.0 - (p.y + 1.0) * 0.5);

        // 0 at the hinge (bottom edge), 1 at the far edge.
        float fromHinge = (p.y + 1.0) * 0.5;

        // Keystone: pull the top edge in. Small on purpose.
        float keystone = u.perspective * u.fold;
        float narrow = 1.0 - keystone * fromHinge;

        float2 pos = float2(p.x * narrow, p.y);

        // Bow the sheet out of plane, which after the keystone reads as a panel
        // flexing rather than a rigid card. Zero at both edges.
        pos.y += u.curvature * u.fold * sin(fromHinge * M_PI_F) * 0.06;

        // Scale so the narrowed top still reaches the screen edge. Without this
        // the keystone would expose background down both sides.
        float coverage = 1.0 / max(1.0 - keystone, 0.2);
        pos *= coverage;

        VertexOut out;
        out.position = float4(pos, 0.0, 1.0);
        out.uv = uv;
        // Distance from the viewer, 0 at the hinge and 1 at the far edge. Drives
        // everything that should fall off with depth.
        out.depth = fromHinge;
        // The far edge leans away and catches slightly less light. Kept gentle:
        // a real closing lid stays bright until the backlight cuts, and dimming
        // it hard just makes the softening harder to see.
        out.shade = mix(1.0, 1.0 - 0.14 * fromHinge, u.fold);
        return out;
    }

    fragment float4 foldFragment(VertexOut in [[stage_in]],
                                 texture2d<float> sharp  [[texture(0)]],
                                 texture2d<float> blurred [[texture(1)]],
                                 constant FoldUniforms &u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        constexpr sampler mipSampler(filter::linear, mip_filter::linear,
                                     address::clamp_to_edge);

        // Blur is the effect. Width comes from the mip chain rather than from a
        // wider kernel: nine taps spread across forty texels sample a comb, not
        // a gaussian, and the gaps show up as ghosting of anything with strong
        // horizontal or vertical structure. Each mip level doubles the blur for
        // one bilinear fetch, and interpolating between levels keeps the ramp
        // continuous as the fold progresses.
        float lod = u.blurLOD * (0.55 + 0.75 * in.depth);
        float focus = clamp(u.blurMix * (0.55 + 0.75 * in.depth), 0.0, 1.0);
        float3 color = mix(sharp.sample(s, in.uv).rgb,
                           blurred.sample(mipSampler, in.uv, level(lod)).rgb,
                           focus);

        color *= in.shade;
        color *= 1.0 - u.darkening * u.fold;

        // Shadow gathering along the far edge, which is both the part swinging
        // down toward the deck and the part furthest away.
        float shadow = pow(in.depth, 1.8) * u.shadowStrength * u.fold;
        color *= 1.0 - shadow;

        // A soft band of light travelling with the fold, so it reads as a
        // reflection moving across glass rather than a fixed gloss.
        float sweep = in.uv.y - (1.0 - u.fold * 1.7);
        float band = exp(-(sweep * sweep) / 0.02);
        color += band * u.sheen * u.fold * 0.35;

        // Fully opaque throughout. The panel covers the screen, so there is
        // never anything behind it that should show through.
        return float4(color, 1.0);
    }
    """
}
