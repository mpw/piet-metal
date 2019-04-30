//  Copyright 2019 The xi-editor authors.

#include <metal_stdlib>
using namespace metal;

#include "PietShaderTypes.h"

typedef struct {
    float4 clipSpacePosition [[position]];
    float2 textureCoordinate;
} RenderData;

vertex RenderData
vertexShader(uint vertexID [[ vertex_id ]],
             constant RenderVertex *vertexArray [[ buffer(RenderVertexInputIndexVertices) ]])
{
    RenderData out;
    float2 clipSpacePosition = vertexArray[vertexID].position;
    out.clipSpacePosition.xy = clipSpacePosition;
    out.clipSpacePosition.z = 0.0;
    out.clipSpacePosition.w = 1.0;
    out.textureCoordinate = vertexArray[vertexID].textureCoordinate;
    return out;
}

fragment float4 fragmentShader(RenderData in [[stage_in]],
                               texture2d<half> texture [[ texture(0) ]]) {
    const half4 sample = texture.read(uint2(in.textureCoordinate));
    return float4(sample);
}

kernel void
renderKernel(texture2d<half, access::write> outTexture [[texture(0)]],
             device ushort4 *tiles [[buffer(0)]],
             uint2 gid [[thread_position_in_grid]],
             uint2 tgid [[threadgroup_position_in_grid]])
{
    uint tileIx = tgid.y * maxTilesWidth + tgid.x;
    device ushort4 *src = tiles + tileIx * (tileBufSize / 2);
    uint x = gid.x;
    uint y = gid.y;
    half3 rgb = half3((x & 255) / 255.0, (y & 255) / 255.0, 0);
    uint n = src[0].x;
    for (uint i = 1; i < n; i++) {
        ushort4 bbox = src[i];
        if (x >= bbox.x && x < bbox.z && y >= bbox.y && y < bbox.w) {
            float x0 = bbox.x;
            float y0 = bbox.y;
            float x1 = bbox.z;
            float y1 = bbox.w;
            float xc = 0.5 * (x0 + x1);
            float yc = 0.5 * (y0 + y1);
            float dx = x - xc;
            float dy = y - yc;
            float r = sqrt(dx * dx + dy * dy);
            // I should make this shade an ellipse properly but am too lazy.
            float circleR = min(xc - x0, yc - y0);
            float alpha = 0.5 * saturate(circleR - r);
            rgb = mix(rgb, half3(1), alpha);
        }
    }
    outTexture.write(half4(rgb, 1), gid);
}

kernel void
tileKernel(device ushort4 *scene [[buffer(0)]],
           device ushort4 *tiles [[buffer(1)]],
           uint2 gid [[thread_position_in_grid]],
           uint tgix [[simdgroup_index_in_threadgroup]],
           uint tix [[thread_index_in_simdgroup]])
{
    threadgroup uint bitmap[8];

    uint tileIx = gid.y * maxTilesWidth + gid.x;
    ushort x0 = gid.x * tileWidth;
    ushort y0 = gid.y * tileHeight;
    device ushort4 *dst = tiles + tileIx * (tileBufSize / 2);

    ushort tgx0 = (gid.x & ~15) * tileWidth;
    ushort tgy0 = (gid.y & ~15) * tileHeight;
    const ushort tgtw = 16 * 16;
    const ushort tgth = 16 * 16;
    uint j = 1;
    for (uint i = 0; i < nCircles; i += 256) {
        ushort4 bbox = scene[i + tgix * 32 + tix];
        simd_vote vote = simd_ballot(bbox.z >= tgx0 && bbox.x < tgx0 + tgtw && bbox.w >= tgy0 && bbox.y < tgy0 + tgth);
        if (tix == 0) {
            bitmap[tgix & 7] = simd_vote::vote_t(vote);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint slice = 0; slice < 8; slice++) {
            uint v = bitmap[slice];
            while (v) {
                uint k = ctz(v);
                bbox = scene[i + slice * 32 + k];
                if (bbox.z >= x0 && bbox.x < x0 + tileWidth && bbox.w >= y0 && bbox.y < y0 + tileHeight) {
                    dst[j++] = bbox;
                }
                v &= ~(1 << k);  // aka v &= (v - 1)
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    dst[0] = ushort4(j, 0, 0, 0);
}
