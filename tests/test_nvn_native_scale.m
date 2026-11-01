#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include "../host/nvn_resample.inc"

// The resampling behind native-scale copies and readbacks: a scaled texture read back at guest size gives the guest
// texels, a guest texture written into a scaled one fills every scaled texel from the guest texel it covers, and the
// round trip keeps the bytes, for float, sRGB, integer and depth formats.
static id<MTLDevice> dev; static id<MTLCommandQueue> queue;

static id<MTLTexture> texture(MTLPixelFormat pf, MTLTextureType type, NSUInteger w, NSUInteger h, NSUInteger levels, NSUInteger slices) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:w height:h mipmapped:NO];
    d.textureType = type; d.mipmapLevelCount = levels; d.arrayLength = slices;
    d.storageMode = MTLStorageModePrivate; d.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    id<MTLTexture> t = [dev newTextureWithDescriptor:d];
    assert(t);
    return t;
}
static void upload(id<MTLTexture> t, unsigned level, unsigned slice, const void *bytes, size_t bpp) {
    NSUInteger w = MAX(t.width >> level, 1u), h = MAX(t.height >> level, 1u);
    id<MTLBuffer> b = [dev newBufferWithBytes:bytes length:w * h * bpp options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [queue commandBuffer]; id<MTLBlitCommandEncoder> e = [cb blitCommandEncoder];
    [e copyFromBuffer:b sourceOffset:0 sourceBytesPerRow:w * bpp sourceBytesPerImage:w * h * bpp sourceSize:MTLSizeMake(w, h, 1)
            toTexture:t destinationSlice:slice destinationLevel:level destinationOrigin:MTLOriginMake(0, 0, 0)];
    [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
}
// Resamples on an old-queue command buffer, as CPU texel reads do, and returns the bytes of the result.
static NSData *resample(id<MTLTexture> src, unsigned level, unsigned slice, double ox, double oy, double r, NSUInteger w, NSUInteger h, size_t bpp, MTLPixelFormat *format) {
    zelda_resample_job job;
    if (!zelda_resample_prepare(dev, src, level, slice, ox, oy, r, w, h, &job)) return nil;
    id<MTLBuffer> b = [dev newBufferWithLength:w * h * bpp options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    zelda_resample_legacy(cb, &job);
    id<MTLBlitCommandEncoder> e = [cb blitCommandEncoder];
    [e copyFromTexture:job.out sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1)
              toBuffer:b destinationOffset:0 destinationBytesPerRow:w * bpp destinationBytesPerImage:w * h * bpp];
    [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
    assert(cb.status == MTLCommandBufferStatusCompleted);
    if (format) *format = job.out.pixelFormat;
    return [NSData dataWithBytes:b.contents length:w * h * bpp];
}

// 2x RGBA8: each guest texel stored as a 2x2 block; a guest rectangle reads back its texels.
static void test_downscale_rgba8(void) {
    enum { W = 8, H = 6, S = 2 };
    uint32_t scaled[W * S * H * S], want[W * H];
    for (int y = 0; y < H * S; y++) for (int x = 0; x < W * S; x++) scaled[y * W * S + x] = 0xff000000u | (uint32_t)(y / S) << 8 | (uint32_t)(x / S);
    id<MTLTexture> t = texture(MTLPixelFormatRGBA8Unorm, MTLTextureType2D, W * S, H * S, 1, 1);
    upload(t, 0, 0, scaled, 4);
    NSData *got = resample(t, 0, 0, 0, 0, S, W, H, 4, NULL);
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) want[y * W + x] = 0xff000000u | (uint32_t)y << 8 | (uint32_t)x;
    assert(got && !memcmp(got.bytes, want, sizeof want));
    got = resample(t, 0, 0, 3 * S, 2 * S, S, 4, 3, 4, NULL);   // guest rectangle at 3,2 of 4x3
    const uint32_t *g = got.bytes;
    for (int y = 0; y < 3; y++) for (int x = 0; x < 4; x++) assert(g[y * 4 + x] == (0xff000000u | (uint32_t)(y + 2) << 8 | (uint32_t)(x + 3)));
}
// 1.5x R32Uint: upscaled texel X covers guest texel floor((X + 0.5) / 1.5); scaling back returns the guest texels.
static void test_upscale_round_trip_uint(void) {
    enum { W = 8, H = 6 };
    const double s = 1.5; const NSUInteger SW = 12, SH = 9;
    uint32_t guest[W * H];
    for (int i = 0; i < W * H; i++) guest[i] = 1000u + (uint32_t)i * 7u;
    id<MTLTexture> t = texture(MTLPixelFormatR32Uint, MTLTextureType2D, W, H, 1, 1);
    upload(t, 0, 0, guest, 4);
    NSData *up = resample(t, 0, 0, 0, 0, 1 / s, SW, SH, 4, NULL);
    const uint32_t *u = up.bytes;
    for (NSUInteger y = 0; y < SH; y++) for (NSUInteger x = 0; x < SW; x++)
        assert(u[y * SW + x] == guest[(int)floor((y + 0.5) / s) * W + (int)floor((x + 0.5) / s)]);
    id<MTLTexture> scaled = texture(MTLPixelFormatR32Uint, MTLTextureType2D, SW, SH, 1, 1);
    upload(scaled, 0, 0, u, 4);
    NSData *back = resample(scaled, 0, 0, 0, 0, s, W, H, 4, NULL);
    assert(!memcmp(back.bytes, guest, sizeof guest));
}
// A guest rectangle written into a scaled target: the origin of the scaled rectangle may start inside a guest texel
// (floor(3 * 1.5) = 4 covers guest 2.67), which reads that texel, not the one before it.
static void test_partial_upscale_origin(void) {
    enum { W = 4, H = 4 };
    int16_t guest[W * H * 4];
    for (int i = 0; i < W * H * 4; i++) guest[i] = (int16_t)(-300 + i * 11);
    id<MTLTexture> t = texture(MTLPixelFormatRGBA16Sint, MTLTextureType2D, W, H, 1, 1);
    upload(t, 0, 0, guest, 8);
    const double s = 1.5; const int gx = 3, gy = 1;   // the copy's guest origin in the target
    NSUInteger x0 = (NSUInteger)floor(gx * s), y0 = (NSUInteger)floor(gy * s), x1 = (NSUInteger)ceil((gx + W) * s), y1 = (NSUInteger)ceil((gy + H) * s);
    NSData *got = resample(t, 0, 0, x0 / s - gx, y0 / s - gy, 1 / s, x1 - x0, y1 - y0, 8, NULL);
    const int16_t *g = got.bytes;
    for (NSUInteger y = 0; y < y1 - y0; y++) for (NSUInteger x = 0; x < x1 - x0; x++) {
        int sx = (int)floor((x0 + x + 0.5) / s) - gx, sy = (int)floor((y0 + y + 0.5) / s) - gy;
        sx = sx < 0 ? 0 : sx >= W ? W - 1 : sx; sy = sy < 0 ? 0 : sy >= H ? H - 1 : sy;
        assert(!memcmp(g + (y * (x1 - x0) + x) * 4, guest + (sy * W + sx) * 4, 8));
    }
}
// sRGB keeps its bytes through a 2x upscale and back (decoded on read, encoded by the kernel on write).
static void test_srgb_round_trip(void) {
    enum { W = 16, H = 16 };
    uint8_t guest[W * H * 4];
    for (int i = 0; i < W * H; i++) { guest[i * 4] = (uint8_t)i; guest[i * 4 + 1] = (uint8_t)(255 - i); guest[i * 4 + 2] = (uint8_t)(i * 37); guest[i * 4 + 3] = (uint8_t)(i * 3); }
    id<MTLTexture> t = texture(MTLPixelFormatRGBA8Unorm_sRGB, MTLTextureType2D, W, H, 1, 1);
    upload(t, 0, 0, guest, 4);
    MTLPixelFormat pf;
    NSData *up = resample(t, 0, 0, 0, 0, 0.5, W * 2, H * 2, 4, &pf);
    assert(pf == MTLPixelFormatRGBA8Unorm_sRGB);
    id<MTLTexture> scaled = texture(MTLPixelFormatRGBA8Unorm_sRGB, MTLTextureType2D, W * 2, H * 2, 1, 1);
    upload(scaled, 0, 0, up.bytes, 4);
    NSData *back = resample(scaled, 0, 0, 0, 0, 2, W, H, 4, NULL);
    assert(!memcmp(back.bytes, guest, sizeof guest));
}
// Depth reads back as a color format of the same bytes; a 2D array's level 1 of slice 1 is the one read.
static void test_depth(void) {
    enum { W = 6, H = 4 };
    float d32[W * 2 * H * 2];
    for (int y = 0; y < H * 2; y++) for (int x = 0; x < W * 2; x++) d32[y * W * 2 + x] = (float)((y / 2) * W + x / 2) / 64.0f;
    id<MTLTexture> t = texture(MTLPixelFormatDepth32Float, MTLTextureType2D, W * 2, H * 2, 1, 1);
    upload(t, 0, 0, d32, 4);
    MTLPixelFormat pf;
    NSData *got = resample(t, 0, 0, 0, 0, 2, W, H, 4, &pf);
    assert(pf == MTLPixelFormatR32Float);
    for (int i = 0; i < W * H; i++) assert(((const float *)got.bytes)[i] == (float)i / 64.0f);

    uint16_t d16[W * 2 * H * 2], zero[W * 4 * H * 4] = {0};
    for (int y = 0; y < H * 2; y++) for (int x = 0; x < W * 2; x++) d16[y * W * 2 + x] = (uint16_t)(((y / 2) * W + x / 2) * 1000 + 7);
    id<MTLTexture> a = texture(MTLPixelFormatDepth16Unorm, MTLTextureType2DArray, W * 4, H * 4, 2, 2);
    upload(a, 0, 1, zero, 2); upload(a, 1, 0, zero, 2); upload(a, 1, 1, d16, 2);
    got = resample(a, 1, 1, 0, 0, 2, W, H, 2, &pf);
    assert(pf == MTLPixelFormatR16Unorm);
    for (int i = 0; i < W * H; i++) assert(((const uint16_t *)got.bytes)[i] == (uint16_t)(i * 1000 + 7));
}
static void test_kinds(void) {
    MTLPixelFormat pf, lpf;
    assert(zelda_resample_kind(MTLPixelFormatRGBA16Float, &pf, &lpf) == 0 && pf == lpf);
    assert(zelda_resample_kind(MTLPixelFormatRG11B10Float, &pf, &lpf) == 0);
    assert(zelda_resample_kind(MTLPixelFormatBGRA8Unorm_sRGB, &pf, &lpf) == 0 && lpf == MTLPixelFormatBGRA8Unorm);
    assert(zelda_resample_kind(MTLPixelFormatRGB10A2Uint, &pf, &lpf) == 1);
    assert(zelda_resample_kind(MTLPixelFormatR8Sint, &pf, &lpf) == 2);
    assert(zelda_resample_kind(MTLPixelFormatDepth16Unorm, &pf, &lpf) == 3 && pf == MTLPixelFormatR16Unorm);
    assert(zelda_resample_kind(MTLPixelFormatDepth32Float_Stencil8, &pf, &lpf) < 0);
    assert(zelda_resample_kind(MTLPixelFormatStencil8, &pf, &lpf) < 0);
    assert(zelda_resample_kind(MTLPixelFormatBC1_RGBA, &pf, &lpf) < 0);
    assert(zelda_resample_kind(MTLPixelFormatB5G6R5Unorm, &pf, &lpf) < 0);
}

int main(void) {
    @autoreleasepool {
        dev = MTLCreateSystemDefaultDevice(); queue = [dev newCommandQueue];
        assert(dev && queue);
        test_kinds();
        test_downscale_rgba8();
        test_upscale_round_trip_uint();
        test_partial_upscale_origin();
        test_srgb_round_trip();
        test_depth();
        printf("native scale resample: ok\n");
    }
    return 0;
}
