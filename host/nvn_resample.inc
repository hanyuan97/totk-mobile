// Native-resolution rendering (nvn_native_scale.inc): the resampling behind copies and readbacks between scales,
// standalone for tests (tests/test_nvn_native_scale.m).
// Copies and readbacks between scales go through a texture resampled by nearest texel, then a blit. Depth is read
// into a color format of the same bytes (Depth32Float as R32Float, Depth16Unorm as R16Unorm), and written back to a
// depth texture through a buffer. sRGB is written through a linear view, encoded by the kernel.
static const char k_zelda_resample_msl[] =
"#include <metal_stdlib>\nusing namespace metal;\n"
"struct P { float2 o; float2 r; uint2 n; uint srgb; uint pad; };\n"
"static uint2 at(constant P &p, uint2 g, uint w, uint h) { return uint2(clamp(p.o + (float2(g) + 0.5) * p.r, 0.0, float2(w - 1, h - 1))); }\n"
"static float3 enc(float3 c) { c = saturate(c); return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308); }\n"
"kernel void rs_f(texture2d<float> s [[texture(0)]], texture2d<float, access::write> d [[texture(1)]], constant P &p [[buffer(0)]], uint2 g [[thread_position_in_grid]]) {\n"
"  if (any(g >= p.n)) return; float4 v = s.read(at(p, g, s.get_width(), s.get_height())); if (p.srgb) v.rgb = enc(v.rgb); d.write(v, g); }\n"
"kernel void rs_u(texture2d<uint> s [[texture(0)]], texture2d<uint, access::write> d [[texture(1)]], constant P &p [[buffer(0)]], uint2 g [[thread_position_in_grid]]) {\n"
"  if (any(g >= p.n)) return; d.write(s.read(at(p, g, s.get_width(), s.get_height())), g); }\n"
"kernel void rs_i(texture2d<int> s [[texture(0)]], texture2d<int, access::write> d [[texture(1)]], constant P &p [[buffer(0)]], uint2 g [[thread_position_in_grid]]) {\n"
"  if (any(g >= p.n)) return; d.write(s.read(at(p, g, s.get_width(), s.get_height())), g); }\n"
"kernel void rs_d(depth2d<float> s [[texture(0)]], texture2d<float, access::write> d [[texture(1)]], constant P &p [[buffer(0)]], uint2 g [[thread_position_in_grid]]) {\n"
"  if (any(g >= p.n)) return; d.write(float4(s.read(at(p, g, s.get_width(), s.get_height()))), g); }\n";
// Kernel of a pixel format (0 float, 1 uint, 2 sint, 3 depth) and the format the resampled texture gets; -1 when
// none fits (stencil, compressed).
static int zelda_resample_kind(MTLPixelFormat pf, MTLPixelFormat *out, MTLPixelFormat *linear) {
    *out = pf; *linear = pf;
    switch (pf) {
    case MTLPixelFormatDepth32Float: *out = *linear = MTLPixelFormatR32Float; return 3;
    case MTLPixelFormatDepth16Unorm: *out = *linear = MTLPixelFormatR16Unorm; return 3;
    case MTLPixelFormatRGBA8Unorm_sRGB: *linear = MTLPixelFormatRGBA8Unorm; return 0;
    case MTLPixelFormatBGRA8Unorm_sRGB: *linear = MTLPixelFormatBGRA8Unorm; return 0;
    case MTLPixelFormatR8Uint: case MTLPixelFormatR16Uint: case MTLPixelFormatRG8Uint: case MTLPixelFormatR32Uint: case MTLPixelFormatRG16Uint:
    case MTLPixelFormatRGBA8Uint: case MTLPixelFormatRGB10A2Uint: case MTLPixelFormatRG32Uint: case MTLPixelFormatRGBA16Uint: case MTLPixelFormatRGBA32Uint: return 1;
    case MTLPixelFormatR8Sint: case MTLPixelFormatR16Sint: case MTLPixelFormatRG8Sint: case MTLPixelFormatR32Sint: case MTLPixelFormatRG16Sint:
    case MTLPixelFormatRGBA8Sint: case MTLPixelFormatRG32Sint: case MTLPixelFormatRGBA16Sint: case MTLPixelFormatRGBA32Sint: return 2;
    case MTLPixelFormatDepth32Float_Stencil8: case MTLPixelFormatStencil8: case MTLPixelFormatX32_Stencil8: case MTLPixelFormatR8Unorm_sRGB:
    case MTLPixelFormatRG8Unorm_sRGB: case MTLPixelFormatB5G6R5Unorm: case MTLPixelFormatA1BGR5Unorm: case MTLPixelFormatABGR4Unorm:
    case MTLPixelFormatBGR5A1Unorm: return -1;   // not shader-writable
    default: return pf >= MTLPixelFormatR8Unorm && pf < MTLPixelFormatBC1_RGBA ? 0 : -1;   // compressed from BC1 on
    }
}
static id<MTLComputePipelineState> zelda_resample_pipeline(id<MTLDevice> dev, int kind) {
    static id<MTLComputePipelineState> ps[4]; static int failed;
    if (!ps[0] && !failed) {
        NSError *e = nil; id<MTLLibrary> lib = [dev newLibraryWithSource:@(k_zelda_resample_msl) options:nil error:&e];
        const char *names[4] = {"rs_f", "rs_u", "rs_i", "rs_d"};
        for (int i = 0; i < 4 && lib; i++) { id<MTLFunction> f = [lib newFunctionWithName:@(names[i])]; ps[i] = f ? [dev newComputePipelineStateWithFunction:f error:&e] : nil; }
        if (!ps[0] || !ps[1] || !ps[2] || !ps[3]) { failed = 1; ps[0] = nil; fprintf(stderr, "[dm] [nvn-mtl] ERROR: Native scale: resample pipelines failed: %s\n", e.localizedDescription.UTF8String); }
    }
    return kind >= 0 && kind < 4 ? ps[kind] : nil;
}
typedef struct { float o[2], r[2]; uint32_t n[2], srgb, pad; } zelda_resample_params;
typedef struct { id<MTLComputePipelineState> ps; id<MTLTexture> out, src_view, out_view; zelda_resample_params p; MTLSize groups, group; } zelda_resample_job;
// A job making a new w x h texture whose texel (i, j) is src's (level, slice) texel at o + (i + 0.5, j + 0.5) * r;
// 0 when the format has no kernel or Metal objects cannot be made.
static int zelda_resample_prepare(id<MTLDevice> dev, id<MTLTexture> src, unsigned level, unsigned slice, double ox, double oy, double r, NSUInteger w, NSUInteger h,
                                  zelda_resample_job *job) {
    MTLPixelFormat pf, lpf; int kind = zelda_resample_kind(src.pixelFormat, &pf, &lpf);
    if (kind < 0 || !w || !h || !(job->ps = zelda_resample_pipeline(dev, kind))) return 0;
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:w height:h mipmapped:NO];
    d.storageMode = MTLStorageModePrivate; d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | (lpf != pf ? MTLTextureUsagePixelFormatView : 0);
    job->out = [dev newTextureWithDescriptor:d];
    job->src_view = [src newTextureViewWithPixelFormat:src.pixelFormat textureType:MTLTextureType2D levels:NSMakeRange(level, 1) slices:NSMakeRange(slice, 1)];
    job->out_view = lpf != pf ? [job->out newTextureViewWithPixelFormat:lpf] : job->out;
    if (!job->out || !job->src_view || !job->out_view) return 0;
    job->p = (zelda_resample_params){{(float)ox, (float)oy}, {(float)r, (float)r}, {(uint32_t)w, (uint32_t)h}, lpf != pf, 0};
    job->groups = MTLSizeMake((w + 7) / 8, (h + 7) / 8, 1); job->group = MTLSizeMake(8, 8, 1);
    return 1;
}
// The job on an old-queue command buffer: tracked resources, bound directly.
static void zelda_resample_legacy(id<MTLCommandBuffer> cb, const zelda_resample_job *job) {
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:job->ps]; [ce setTexture:job->src_view atIndex:0]; [ce setTexture:job->out_view atIndex:1];
    [ce setBytes:&job->p length:sizeof job->p atIndex:0];
    [ce dispatchThreadgroups:job->groups threadsPerThreadgroup:job->group]; [ce endEncoding];
}
