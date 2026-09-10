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
    // The panel is a subdivided grid in model space with x and y both in
    // [-1, 1]. The hinge is the bottom edge, y = -1. Folding rotates the sheet
    // about that edge, so the hinge stays pinned while the far edge swings away
    // from the viewer and drops.
    //
    // Perspective is the classic single-term projection: divide x and y by
    // (1 + z * k). Because z is zero at the hinge, the hinge neither moves nor
    // scales, which is exactly how a real lid behaves.
    vertex VertexOut foldVertex(uint vid [[vertex_id]],
                                constant float2 *grid [[buffer(0)]],
                                constant FoldUniforms &u [[buffer(1)]]) {
        float2 p = grid[vid];              // x, y each in [-1, 1]
        float2 uv = float2((p.x + 1.0) * 0.5, 1.0 - (p.y + 1.0) * 0.5);

        // Distance from the hinge, 0 at the bottom edge and 2 at the top.
        float fromHinge = p.y + 1.0;

        // Rotate about the hinge. 82 degrees at full fold leaves the panel just
        // shy of edge-on, where it would vanish to a line.
        float angle = u.fold * 1.43;       // radians, about 82 degrees
        float rotatedY = fromHinge * cos(angle);
        float z        = fromHinge * sin(angle);

        // Bow the sheet slightly out of plane so it reads as a physical panel
        // rather than a rigid card. Zero at both edges, maximum in the middle.
        z -= u.curvature * u.fold * sin(fromHinge * M_PI_F * 0.5) * 0.35;

        float3 pos = float3(p.x, rotatedY - 1.0, z);

        // Single-term perspective divide.
        float w = 1.0 + pos.z * u.perspective;
        w = max(w, 0.05);                  // never divide through zero
        float2 projected = pos.xy / w;

        VertexOut out;
        out.position = float4(projected, 0.0, 1.0);
        out.uv = uv;
        // Normalised distance from the viewer, 0 at the pinned hinge and 1 at the
        // far edge. Everything that should fall off with distance keys off this.
        out.depth = clamp(z * 0.5, 0.0, 1.0);

        // Lambert-ish term: as the sheet tilts away from the viewer it catches
        // less light, so the far edge darkens more than the hinge.
        float facing = cos(angle);
        out.shade = mix(1.0, facing, u.fold * 0.65);
        return out;
    }

    fragment float4 foldFragment(VertexOut in [[stage_in]],
                                 texture2d<float> sharp  [[texture(0)]],
                                 texture2d<float> blurred [[texture(1)]],
                                 constant FoldUniforms &u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);

        // Blur deepens with distance rather than being flat across the panel.
        // A real lens focused on the near edge throws the receding edge out of
        // focus first, and matching that is most of what sells the tilt as depth
        // rather than as a squashed picture.
        float focus = clamp(u.blurMix * (0.35 + 1.15 * in.depth), 0.0, 1.0);
        float3 color = mix(sharp.sample(s, in.uv).rgb,
                           blurred.sample(s, in.uv).rgb,
                           focus);

        // Per-vertex facing term, plus a global pull toward black.
        color *= in.shade;
        color *= 1.0 - u.darkening * u.fold;

        // Shadow gathers along the far edge — the part swinging down toward the
        // deck, which is both what occludes first and what is furthest away.
        float shadow = pow(in.depth, 1.6) * u.shadowStrength * u.fold;
        color *= 1.0 - shadow;

        // A soft band of light rakes across the panel as it tilts. It travels
        // with the fold so it reads as a reflection moving, not a static gloss,
        // and it is strongest where the panel is most edge-on to the viewer.
        float sweep = in.uv.y - (1.0 - u.fold * 1.7);
        float band = exp(-(sweep * sweep) / 0.012);
        color += band * u.sheen * u.fold * 0.55 * (0.4 + 0.6 * in.depth);

        // Fade the very last of the fold to nothing so the panel does not pop
        // out of existence when it reaches edge-on.
        float alpha = smoothstep(1.0, 0.94, u.fold);

        return float4(color * alpha, alpha);
    }
    """
}
