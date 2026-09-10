import Foundation

enum Shaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct FoldUniforms {
        float fold;
        float perspective;
        float darkening;
        float shadowStrength;
        float sheen;
        float curvature;
        float blurMix;
        float blurLOD;
        float vignette;
        float aspect;
    };

    struct BlurUniforms {
        float2 texelStep;
        float  radius;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
        float  depth;
        float  along;
        float  shade;
    };

    struct FSOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex FSOut fullscreenVertex(uint vid [[vertex_id]]) {
        float2 uv = float2((vid << 1) & 2, vid & 2);
        FSOut out;
        out.uv = uv;
        out.position = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
        return out;
    }

    fragment float4 blurFragment(FSOut in [[stage_in]],
                                 texture2d<float> src [[texture(0)]],
                                 constant BlurUniforms &u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);

        const float weights[5] = { 0.2270270270, 0.1945945946, 0.1216216216,
                                   0.0540540541, 0.0162162162 };
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

    vertex VertexOut foldVertex(uint vid [[vertex_id]],
                                constant float2 *grid [[buffer(0)]],
                                constant FoldUniforms &u [[buffer(1)]]) {
        float2 p = grid[vid];
        float2 uv = float2((p.x + 1.0) * 0.5, 1.0 - (p.y + 1.0) * 0.5);

        float fromHinge = p.y + 1.0;

        float angle = u.fold * 1.43;
        float rotatedY = fromHinge * cos(angle);
        float z        = fromHinge * sin(angle);

        z -= u.curvature * u.fold * sin(fromHinge * M_PI_F * 0.5) * 0.35;

        float3 pos = float3(p.x, rotatedY - 1.0, z);

        float w = 1.0 + pos.z * u.perspective;
        w = max(w, 0.05);
        float2 projected = pos.xy / w;

        VertexOut out;
        out.position = float4(projected, 0.0, 1.0);
        out.uv = uv;
        out.depth = clamp(z * 0.5, 0.0, 1.0);
        out.along = fromHinge * 0.5;

        float facing = cos(angle);
        out.shade = mix(1.0, facing, u.fold * 0.65) * (1.0 - u.fold * 0.22 * (fromHinge * 0.5));
        return out;
    }

    fragment float4 foldFragment(VertexOut in [[stage_in]],
                                 texture2d<float> sharp  [[texture(0)]],
                                 texture2d<float> blurred [[texture(1)]],
                                 constant FoldUniforms &u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        constexpr sampler mipSampler(filter::linear, mip_filter::linear,
                                     address::clamp_to_edge);

        float along = clamp(in.along, 0.0, 1.0);
        float flatten = u.fold * u.fold;
        float levelRamp = mix(pow(along, 1.5), 1.0, flatten);
        float mixRamp = mix(smoothstep(0.0, 0.45, along), 1.0, flatten);
        float lod = u.blurLOD * levelRamp;
        float focus = clamp(u.blurMix * mixRamp, 0.0, 1.0);
        float3 color = mix(sharp.sample(s, in.uv).rgb,
                           blurred.sample(mipSampler, in.uv, level(lod)).rgb,
                           focus);

        color *= in.shade;
        color *= 1.0 - u.darkening * u.fold;

        float topFall = pow(in.along, 1.6) * u.shadowStrength * u.fold;
        color *= 1.0 - topFall;

        float2 fromCentre = in.uv - 0.5;
        fromCentre.y -= 0.12;
        float corner = clamp(dot(fromCentre * float2(1.35, 1.75),
                                 fromCentre * float2(1.35, 1.75)) * 2.4, 0.0, 1.0);
        color *= 1.0 - clamp(corner * u.vignette * u.fold, 0.0, 1.0);

        float sweep = in.uv.y - (1.0 - u.fold * 1.7);
        float band = exp(-(sweep * sweep) / 0.02);
        color += band * u.sheen * u.fold * 0.35;

        float2 fromMiddle = abs(in.uv - 0.5) * 2.0;
        float shape = pow(pow(fromMiddle.x, 5.0) + pow(fromMiddle.y, 5.0), 0.2);
        float feather = mix(0.07, 0.34, levelRamp) * clamp(u.fold * 2.2, 0.0, 1.0);
        float edgeAlpha = 1.0 - smoothstep(1.0 - feather, 1.0 + feather * 0.15, shape);

        float alpha = smoothstep(1.0, 0.94, u.fold) * edgeAlpha;
        return float4(color * alpha, alpha);
    }
    """
}
