// Downscaled presentation. When the game image (or the MetalFX output) is larger than the viewport, as with a native
// scale above the display or MetalFX 4K on a 1440p screen, a single bilinear tap per screen pixel skips source texels
// (aliasing) and softens what it keeps. The present draw then averages each screen pixel's whole footprint with
// n x n bilinear taps (n = the footprint in texels, 2..4) and sharpens the result against its four neighbours' averages, the
// sharpened value clamped to their range so edges do not ring. Strength ZELDA_PRESENT_SHARPEN=0..1 (default 0.5);
// ZELDA_PRESENT_FILTER=0 keeps the plain bilinear draw for comparisons; the input script's sharpen verb changes either
// in play (zelda_present_sharpen). At or above 1:1 nothing changes.
// The parameters follow the crop rectangle and edge clamp in the present buffer: k = (footprint u, footprint v, strength, n).
static const char *k_present_filter_msl =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "struct V { float4 p [[position]]; float2 uv; };\n"
    "vertex V vs(uint id [[vertex_id]]) { float2 uv = float2((id << 1) & 2, id & 2); V o; o.p = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1); o.uv = uv; return o; }\n"
    "struct F { float4 rect; float4 edge; float4 k; };\n"
    "static float4 area(texture2d<float> t, sampler s, constant F& c, float2 uv) {\n"
    "    int n = int(c.k.w); float2 d = c.k.xy / float(n), o = uv - c.k.xy * 0.5 + d * 0.5; float4 a = 0;\n"
    "    for (int j = 0; j < n; j++) for (int i = 0; i < n; i++) a += t.sample(s, clamp(o + d * float2(i, j), c.edge.xy, c.edge.zw));\n"
    "    return a / float(n * n);\n"
    "}\n"
    "fragment float4 fs(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant F& c [[buffer(0)]]) {\n"
    "    float2 uv = in.uv * c.rect.zw + c.rect.xy;\n"
    "    float4 m = area(t, s, c, uv);\n"
    "    if (c.k.z <= 0) return m;\n"
    "    float4 n = area(t, s, c, uv - float2(0, c.k.y)), so = area(t, s, c, uv + float2(0, c.k.y));\n"
    "    float4 w = area(t, s, c, uv - float2(c.k.x, 0)), e = area(t, s, c, uv + float2(c.k.x, 0));\n"
    "    float3 lo = min(m.rgb, min(min(n.rgb, so.rgb), min(w.rgb, e.rgb))), hi = max(m.rgb, max(max(n.rgb, so.rgb), max(w.rgb, e.rgb)));\n"
    "    float3 r = m.rgb + c.k.z * (m.rgb - (n.rgb + so.rgb + w.rgb + e.rgb) * 0.25);\n"
    "    return float4(clamp(r, lo, hi), m.a);\n"
    "}\n";

// Sharpening in percent; -1 = the plain bilinear draw; INT_MIN = not read from the environment yet.
static _Atomic int z_present_sharpen = INT_MIN;
void zelda_present_sharpen(int percent) { atomic_store(&z_present_sharpen, percent < 0 ? -1 : MIN(percent, 100)); }
static int zelda_present_sharpen_percent(void) {
    int v = atomic_load(&z_present_sharpen);
    if (v == INT_MIN) {
        const char *filter = getenv("ZELDA_PRESENT_FILTER"), *sharpen = getenv("ZELDA_PRESENT_SHARPEN");
        int want = filter && !atoi(filter) ? -1 : sharpen ? (int)lround(fmax(fmin(atof(sharpen), 1), 0) * 100) : 50;
        atomic_compare_exchange_strong(&z_present_sharpen, &v, want);
        v = atomic_load(&z_present_sharpen);
    }
    return v;
}

// The pipeline for a present draw of the cw x ch source region into the viewport; fills k[0..3] for the filter.
static id<MTLRenderPipelineState> zelda_present_filter(MTLPixelFormat format, id<MTLTexture> src, NSUInteger cw, NSUInteger ch,
                                                       MTLViewport vp, float *k) {
    int sharpen = zelda_present_sharpen_percent();
    double rx = cw / vp.width, ry = ch / vp.height;
    if (sharpen < 0 || (rx <= 1.001 && ry <= 1.001)) return g_blit_pso;
    static id<MTLRenderPipelineState> pso; static MTLPixelFormat pso_format; static int failed;
    if (!pso || pso_format != format) {
        if (failed) return g_blit_pso;
        NSError *e = nil;
        id<MTLLibrary> lib = [g_dev newLibraryWithSource:@(k_present_filter_msl) options:nil error:&e];
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"vs"]; pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
        pd.colorAttachments[0].pixelFormat = format;
        id<MTLRenderPipelineState> made = lib ? [g_dev newRenderPipelineStateWithDescriptor:pd error:&e] : nil;
        if (!made) { failed = 1; MLOG("ERROR: Present downscale filter unavailable, drawing bilinear: %s", e.localizedDescription.UTF8String); return g_blit_pso; }
        pso = made; pso_format = format;
    }
    double r = fmax(rx, ry);
    k[0] = (float)((double)cw / src.width / vp.width); k[1] = (float)((double)ch / src.height / vp.height);
    k[2] = sharpen / 100.0f; k[3] = (float)fmin(fmax(ceil(r - 0.001), 2), 4);
    static double logged[3];
    if (logged[0] != cw || logged[1] != vp.width || logged[2] != k[2]) {
        logged[0] = cw; logged[1] = vp.width; logged[2] = k[2];
        MLOG("Present downscale %lux%lu -> %.0fx%.0f: %.0fx%.0f taps, sharpen %.2f", (unsigned long)cw, (unsigned long)ch, vp.width, vp.height, k[3], k[3], k[2]);
    }
    return pso;
}
