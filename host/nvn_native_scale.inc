#include "settings.h"
// Native-resolution rendering, the native_scale setting or ZELDA_NATIVE_SCALE=S (1 < S <= 4): render targets get Metal storage S times their guest
// size while the game keeps seeing its own sizes, as Ryujinx's resolution scaling does. Viewports and scissors of a
// scaled pass are multiplied by S, and the support buffer tells the translated shaders the scales: render_scale[0] is
// the pass's (gl_FragCoord is divided by it), render_scale[1 + k] that of the k-th texture binding, images after the
// textures (texelFetch coordinates are multiplied by it, textureSize divided). Ryujinx.Graphics.Shader emits that code
// for 2D textures that are not bindless and not arrays of textures.
// Copies and readbacks between a scaled and an unscaled texture are resampled by nearest texel
// (nvn_native_scale_pass.inc).
// shortcut: passes that mix scales, and stencil or unwritable formats crossing scales, are reported and left wrong;
// Ryujinx rescales such textures to 1x.
static double z_native_scale;
static double zelda_native_scale(void) {
    if (!z_native_scale) {
        const char *e = getenv("ZELDA_NATIVE_SCALE"); int choice = zelda_settings().native_scale;
        double s = e ? atof(e) : choice == ZELDA_NATIVE_2X ? 2 : choice == ZELDA_NATIVE_1_5X ? 1.5 : 1;
        z_native_scale = s > 1 && s <= 4 ? s : 1;
        if (z_native_scale > 1) MLOG("Native scale: render targets at %.2fx their guest size", z_native_scale);
    }
    return z_native_scale;
}
double zelda_native_scale_running(void) { return zelda_native_scale(); }
static NSUInteger zelda_scaled_extent(NSUInteger guest) { return (NSUInteger)ceil(guest * z_native_scale); }

// Which device textures are scaled: 2D and 2D array render targets that are not images, as Ryujinx's
// IsUpscaleCompatible, minus what its UpscaleSafeMode rejects: mip chains, tiny textures, low-resolution 16:9 blur
// targets and 2:1 atlases. Squares stay 1x whatever their format, unlike Ryujinx: a square depth buffer serves cubemap
// faces (environment probes, 64x64), which are not scaled, and shadow maps do not follow the screen resolution.
static int zelda_scale_eligible(const tex_t *t, MTLTextureDescriptor *d) {
    if (zelda_native_scale() == 1 || (t->d.target != 1 && t->d.target != 4 && t->d.target != 7) || !(d.usage & MTLTextureUsageRenderTarget) ||
        (t->d.flags & NVN_TEXTURE_FLAGS_IMAGE) || (d.textureType != MTLTextureType2D && d.textureType != MTLTextureType2DArray)) return 0;
    NSUInteger w = d.width, h = d.height;
    if (d.mipmapLevelCount > 3 || w < 8 || h < 8 || w == h || w == 2 * h) return 0;
    NSUInteger aspect = (NSUInteger)ceil(h / 9.0 * 16.0);
    if (h < 360 && w + 8 >= aspect && w <= aspect + 8) return 0;
    return 1;
}

static NSHashTable *z_scaled_textures;   // base textures created scaled; read by the present thread too
static os_unfair_lock z_scaled_lock = OS_UNFAIR_LOCK_INIT;
static uint64_t z_scaled_count, z_scaled_bytes;
static void zelda_scale_descriptor(const tex_t *t, MTLTextureDescriptor *d) {
    if (!zelda_scale_eligible(t, d)) return;
    d.width = zelda_scaled_extent(d.width); d.height = zelda_scaled_extent(d.height);
}
static void zelda_scale_note(const tex_t *t, id<MTLTexture> texture) {
    if (z_native_scale <= 1 || !texture || texture.width == (t->d.width ? t->d.width : 1)) return;
    os_unfair_lock_lock(&z_scaled_lock);
    if (!z_scaled_textures) z_scaled_textures = [NSHashTable weakObjectsHashTable];
    [z_scaled_textures addObject:texture];
    os_unfair_lock_unlock(&z_scaled_lock);
    z_scaled_count++; z_scaled_bytes += texture.allocatedSize;
    if (z_scaled_count <= 64 || !(z_scaled_count & (z_scaled_count - 1)))
        MLOG("Native scale: target #%llu ser=%llu %ux%u fmt=%lu -> %lux%lu (%.1f MiB scaled in all)", z_scaled_count, t->serial, t->d.width, t->d.height,
             (unsigned long)texture.pixelFormat, (unsigned long)texture.width, (unsigned long)texture.height, z_scaled_bytes / 1048576.0);
}
// The scale of a Metal texture (or a view of one) standing for guest texture t.
static double zelda_texture_scale(const tex_t *t, id<MTLTexture> texture) {
    if (z_native_scale <= 1 || !t || !texture) return 1;
    id<MTLTexture> base = texture.parentTexture ?: texture;
    return base.width == zelda_scaled_extent(t->d.width) && base.height == zelda_scaled_extent(t->d.height) && base.width != t->d.width ? z_native_scale : 1;
}
// The same without the guest texture (present).
static double zelda_texture_scale_of(id<MTLTexture> texture) {
    if (z_native_scale <= 1 || !texture) return 1;
    id<MTLTexture> base = texture.parentTexture ?: texture;
    os_unfair_lock_lock(&z_scaled_lock);
    int scaled = [z_scaled_textures containsObject:base];
    os_unfair_lock_unlock(&z_scaled_lock);
    return scaled ? z_native_scale : 1;
}

// A guest rectangle in a texture of the given scale, in Metal texels.
static MTLRegion zelda_scale_region(double s, int x, int y, int w, int h) {
    if (s == 1) return MTLRegionMake2D(x, y, w, h);
    NSUInteger x0 = (NSUInteger)floor(x * s), y0 = (NSUInteger)floor(y * s), x1 = (NSUInteger)ceil((x + w) * s), y1 = (NSUInteger)ceil((y + h) * s);
    return MTLRegionMake2D(x0, y0, x1 - x0, y1 - y0);
}
// A guest scissor in a target of the given scale.
static p_scissor zelda_scale_scissor(p_scissor s, double scale) {
    if (scale == 1) return s;
    double x0 = floor(s.x * scale), y0 = floor(s.y * scale), x1 = ceil(((double)s.x + s.w) * scale), y1 = ceil(((double)s.y + s.h) * scale);
    s.x = (int)x0; s.y = (int)y0; s.w = (int)MIN(x1 - x0, (double)INT_MAX); s.h = (int)MIN(y1 - y0, (double)INT_MAX);
    return s;
}
// The present crop is in guest texels of the window texture.
static void zelda_present_crop_scale(id<MTLTexture> src, NSUInteger *x, NSUInteger *y, NSUInteger *w, NSUInteger *h) {
    double s = zelda_texture_scale_of(src);
    if (s == 1) return;
    MTLRegion r = zelda_scale_region(s, (int)*x, (int)*y, (int)*w, (int)*h);
    *x = MIN(r.origin.x, src.width - 1); *y = MIN(r.origin.y, src.height - 1);
    *w = MIN(r.size.width, src.width - *x); *h = MIN(r.size.height, src.height - *y);
}
