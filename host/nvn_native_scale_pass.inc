// Native-resolution rendering (nvn_native_scale.inc): the scale of a pass, the scaled support buffer, and reports of
// what does not handle scaled textures yet.
// One attachment for the mixed-pass report: guest size, scale, and for 1x ones what kept them unscaled.
static int zelda_scale_describe(char *out, size_t room, const char *kind, int index, const tex_t *t, id<MTLTexture> texture) {
    double s = zelda_texture_scale(t, texture);
    if (s != 1) return snprintf(out, room, " %s%d=%ux%u@%.2f", kind, index, t->d.width, t->d.height, s);
    int packaged = t->mem && (t->has_layout || (t->pool && (t->pool->flags & (NVN_MEMORY_POOL_FLAGS_CPU_CACHED | NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED))));
    return snprintf(out, room, " %s%d=%ux%u@1[ser=%llu fmt=%lu target=%d flags=%#x levels=%u packaged=%d]", kind, index, t->d.width, t->d.height,
                    t->serial, (unsigned long)(texture.parentTexture ?: texture).pixelFormat, t->d.target, t->d.flags, t->d.levels, packaged);
}
// Scale of the pass being opened: that of its attachments. Passes that mix scales are reported
// (the shortcut in nvn_native_scale.inc) and drawn at the scaled size.
static double z_pass_scale = 1;
static uint64_t z_pass_mixed;
static void zelda_pass_scale(RPD *pd, int n) {
    z_pass_scale = 1;
    if (z_native_scale <= 1) return;
    double s = 0; int mixed = 0;
    for (int i = 0; i < n && i < 8; i++) {
        id<MTLTexture> t = pd.colorAttachments[i].texture;
        if (!t || !R.rt.color[i]) continue;
        double ts = zelda_texture_scale(R.rt.color[i], t);
        if (s && ts != s) mixed = 1; else s = ts;
    }
    id<MTLTexture> dt = pd.depthAttachment.texture ?: pd.stencilAttachment.texture;
    static NSMutableSet *z_noted;   // large 1x targets, reported once each
    for (int i = -1; i < n && i < 8; i++) {
        const tex_t *gt = i < 0 ? R.rt.depth : R.rt.color[i]; id<MTLTexture> mt = i < 0 ? dt : pd.colorAttachments[i].texture;
        if (!gt || !mt || gt->d.width < 640 || zelda_texture_scale(gt, mt) != 1 || z_noted.count >= 48 || [z_noted containsObject:@(gt->serial)]) continue;
        if (!z_noted) z_noted = [NSMutableSet set];
        [z_noted addObject:@(gt->serial)];
        char line[256]; zelda_scale_describe(line, sizeof line, i < 0 ? "d" : "c", i < 0 ? 0 : i, gt, mt);
        MLOG("Native scale: 1x target in pass %llu:%s", g_stat_pass + 1, line);
    }
    if (dt && R.rt.depth) { double ts = zelda_texture_scale(R.rt.depth, dt); if (s && ts != s) mixed = 1; else s = ts; }
    if (mixed) {
        if (z_pass_mixed++ < 24) {
            char line[1024]; int o = 0;
            for (int i = 0; i < n && i < 8 && o < 900; i++) if (pd.colorAttachments[i].texture && R.rt.color[i])
                o += zelda_scale_describe(line + o, sizeof line - o, "c", i, R.rt.color[i], pd.colorAttachments[i].texture);
            if (dt && R.rt.depth) zelda_scale_describe(line + o, sizeof line - o, "d", 0, R.rt.depth, dt);
            MLOG("ERROR: Native scale: pass %llu mixes scales:%s", g_stat_pass + 1, line);
        }
        s = z_native_scale;
    }
    z_pass_scale = s ? s : 1;
}

// Support buffer of a stage whose pass or textures are scaled (0 when all are 1x): Ryujinx's layout, measured in MSL
// (frag_scale_count at 176, render_scale float4[73] at 192, .x read). Vertex shaders index from 1 + frag_scale_count;
// each stage has its own copy, so the count stays 0 and every stage indexes its own scales from 1.
static uint64_t zelda_support_scaled(NvShader *sh, int nvn_stage, id<MTLBuffer> *buffer) {
    if (z_native_scale <= 1) return 0;
    float scales[73]; int k = 0, any = nvn_stage == 1 && z_pass_scale != 1;
    const tex_t *rt = R.rt.n && R.rt.color[0] ? R.rt.color[0] : R.rt.depth;
    for (int pass = 0; pass < 2; pass++) for (int i = 0; i < sh->rf.nb && k < 72; i++) {
        const nvn_rbind *b = &sh->rf.b[i];
        int tex = b->kind == NVN_RB_TEX || b->kind == NVN_RB_TBUF;
        if (pass == 0 ? !tex : b->kind != NVN_RB_IMG) continue;
        float s = 1;
        if (b->kind == NVN_RB_TEX) {
            int tid = b->reg < 128 ? (int)(S.tex[nvn_stage][b->reg] & 0xfffff) : 0;
            void *tv = NULL;
            if (tid && tid < g_ntreg && zelda_sampled_texture(tid, b->dtt, &tv)) {
                const tex_t *gt = &g_treg[tid].t;
                s = (float)zelda_texture_scale(gt, (__bridge id<MTLTexture>)tv);
                // Ryujinx: a fragment texel fetch from a texture in the target's proportions picks between the
                // scaled texels by gl_FragCoord (a negative scale).
                if (s != 1 && nvn_stage == 1 && rt && rt->d.width * gt->d.height == rt->d.height * gt->d.width) s = -s;
            }
        }
        if (s != 1) any = 1;
        scales[k++] = s;
    }
    if (!any) return 0;
    id<MTLBuffer> db; size_t off = arena_alloc(192 + 16 * 73, &db);
    uint8_t *p = (uint8_t *)db.contents + off;
    memcpy(p, support_buf().contents, 192 + 16 * 73);
    *(float *)(p + 192) = nvn_stage == 1 ? (float)z_pass_scale : 1.0f;
    for (int i = 0; i < k; i++) *(float *)(p + 192 + 16 * (1 + i)) = scales[i];
    *buffer = db;
    return g_cur_arena->gpu + off;
}

// The resampling of nvn_resample.inc, on cb (an old-queue command buffer) or, when cb is nil, on the frame's command
// buffer. nil when the format has no kernel.
static id<MTLTexture> zelda_resample(id<MTLCommandBuffer> cb, id<MTLTexture> src, unsigned level, unsigned slice, double ox, double oy, double r, NSUInteger w, NSUInteger h) {
#if !DM_NVN_M3
    static id<MTL4ArgumentTable> at;
    if (!at) { MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new]; ad.maxTextureBindCount = 2; ad.maxBufferBindCount = 1; at = [g_dev newArgumentTableWithDescriptor:ad error:nil]; }
    if (!at) return nil;
#endif
    zelda_resample_job job;
    if (!zelda_resample_prepare(g_dev, src, level, slice, ox, oy, r, w, h, &job)) return nil;
    if (cb) { zelda_resample_legacy(cb, &job); return job.out; }
    res_add(job.out);
    id<MTLBuffer> pb; size_t off = arena_alloc(sizeof job.p, &pb); memcpy((uint8_t *)pb.contents + off, &job.p, sizeof job.p);
    rp_end(); if (g_blit) { enc_b_end(g_blit); g_blit = nil; }
    CENC ce = (CENC)enc_c_begin(NULL);
#if DM_NVN_M3
    [ce setTexture:job.src_view atIndex:0]; [ce setTexture:job.out_view atIndex:1]; [ce setBuffer:pb offset:off atIndex:0];
#else
    [ce setArgumentTable:at];
    [at setTexture:job.src_view.gpuResourceID atIndex:0]; [at setTexture:job.out_view.gpuResourceID atIndex:1]; [at setAddress:g_cur_arena->gpu + off atIndex:0];
#endif
    enc_c_pso(ce, job.ps); enc_c_dispatch(ce, job.groups, job.group); enc_c_end(ce);
    args_dirty_all();
    defer_obj_unref(job.src_view); if (job.out_view != job.out) defer_obj_unref(job.out_view); defer_obj_release(job.out);   // after this submit has run
    return job.out;
}
// Writes a resampled texture into dst at (slice, level, origin); a depth dst goes through a buffer.
static void zelda_resample_store(id<MTLTexture> tmp, id<MTLTexture> dst, unsigned slice, unsigned level, MTLOrigin o) {
    MTLSize size = MTLSizeMake(tmp.width, tmp.height, 1);
    if (tmp.pixelFormat == dst.pixelFormat) { enc_b_copy_texture(blit(), tmp, 0, 0, MTLOriginMake(0, 0, 0), size, dst, slice, level, o); return; }
    NSUInteger bpp = tmp.pixelFormat == MTLPixelFormatR16Unorm ? 2 : 4;
    id<MTLBuffer> buf = [g_dev newBufferWithLength:tmp.width * tmp.height * bpp options:MTLResourceStorageModePrivate];
    res_add(buf);
    enc_b_copy_texture_buffer(blit(), tmp, 0, 0, MTLOriginMake(0, 0, 0), size, buf, 0, tmp.width * bpp, tmp.width * tmp.height * bpp);
    enc_b_end(g_blit); g_blit = nil;   // the next encoder starts after the copy
    enc_b_copy_buffer_texture(blit(), buf, 0, tmp.width * bpp, tmp.width * tmp.height * bpp, size, dst, slice, level, o);
    defer_obj_release(buf);
}

// Reports of copies and readbacks that see a scaled texture: resampled, or left unscaled when no kernel fits.
static uint64_t z_scale_seen[8];
static void zelda_scale_report(int kind, int ok, const char *what, const tex_t *a, double sa, const tex_t *b, double sb) {
    uint64_t n = ++z_scale_seen[kind * 2 + !ok];
    if (n <= 12 || !(n & (n - 1)))
        MLOG("%sNative scale: %s %s (#%llu): ser=%llu %ux%u@%.2f -> ser=%llu %ux%u@%.2f", ok ? "" : "ERROR: ", what, ok ? "resampled" : "not scaled", n,
             a ? a->serial : 0ull, a ? a->d.width : 0, a ? a->d.height : 0, sa, b ? b->serial : 0ull, b ? b->d.width : 0, b ? b->d.height : 0, sb);
}
// The Metal texels covering a guest rectangle of a level, clamped to it.
static MTLRegion zelda_scale_level_region(id<MTLTexture> t, unsigned level, double s, int x, int y, int w, int h) {
    MTLRegion r = zelda_scale_region(s, x, y, w, h);
    NSUInteger lw = MAX(t.width >> level, 1u), lh = MAX(t.height >> level, 1u);
    r.origin.x = MIN(r.origin.x, lw); r.origin.y = MIN(r.origin.y, lh);
    r.size.width = MIN(r.size.width, lw - r.origin.x); r.size.height = MIN(r.size.height, lh - r.origin.y);
    return r;
}
// A 2D texture copy with a scaled end (returns 1 when done here). One scale: the scaled rectangle is blitted.
// Two scales: the destination's texels are resampled from the source's.
static int zelda_scaled_copy(const p_copy_t2t *c, id<MTLTexture> s, id<MTLTexture> d, unsigned sl, unsigned dl, unsigned sz0, unsigned dz0, int nz) {
    double ss = zelda_texture_scale(c->src, s), ds = zelda_texture_scale(c->dst, d);
    if (ss == 1 && ds == 1) return 0;
    MTLRegion dr = zelda_scale_level_region(d, dl, ds, c->dr.xoffset, c->dr.yoffset, c->dr.width, c->dr.height);
    if (ss != ds) {
        double ox = ss * (c->sr.xoffset - c->dr.xoffset + dr.origin.x / ds), oy = ss * (c->sr.yoffset - c->dr.yoffset + dr.origin.y / ds);
        for (int z = 0; z < nz; z++) {
            id<MTLTexture> tmp = zelda_resample(nil, s, sl, sz0 + c->sr.zoffset + z, ox, oy, ss / ds, dr.size.width, dr.size.height);
            if (!tmp) { zelda_scale_report(0, 0, "texture copy between scales", c->src, ss, c->dst, ds); return 0; }
            zelda_resample_store(tmp, d, dz0 + c->dr.zoffset + z, dl, dr.origin);
        }
        zelda_scale_report(0, 1, "texture copy between scales", c->src, ss, c->dst, ds);
        return 1;
    }
    MTLRegion sr = zelda_scale_level_region(s, sl, ss, c->sr.xoffset, c->sr.yoffset, c->sr.width, c->sr.height);
    NSUInteger w = MIN(sr.size.width, dr.size.width), h = MIN(sr.size.height, dr.size.height);
    if (!w || !h) return 1;
    BENC b = blit();
    for (int z = 0; z < nz; z++)
        enc_b_copy_texture(b, s, sz0 + c->sr.zoffset + z, sl, sr.origin, MTLSizeMake(w, h, 1), d, dz0 + c->dr.zoffset + z, dl, dr.origin);
    return 1;
}
// Texture to buffer from a scaled 2D texture: the guest texels are resampled, then copied (returns 1 when done here).
static int zelda_scaled_t2b(const p_copy_b2t *c, id<MTLTexture> t, unsigned level, unsigned layer0, int nz, id<MTLBuffer> buf, uint64_t off, size_t row, size_t img) {
    double s = zelda_texture_scale(c->tex, t);
    if (s == 1) return 0;
    for (int z = 0; z < nz; z++) {
        id<MTLTexture> tmp = zelda_resample(nil, t, level, layer0 + c->r.zoffset + z, c->r.xoffset * s, c->r.yoffset * s, s, c->r.width, c->r.height);
        if (!tmp) { zelda_scale_report(1, 0, "texture to buffer copy", c->tex, s, NULL, 1); return 0; }
        enc_b_copy_texture_buffer(blit(), tmp, 0, 0, MTLOriginMake(0, 0, 0), MTLSizeMake(c->r.width, c->r.height, 1), buf, off + z * img, row, img);
    }
    zelda_scale_report(1, 1, "texture to buffer copy", c->tex, s, NULL, 1);
    return 1;
}
// Buffer to a scaled 2D texture: the guest texels go into a 1x texture, which is resampled into the scaled one.
static int zelda_scaled_b2t(const p_copy_b2t *c, id<MTLTexture> t, unsigned level, unsigned layer0, int nz, id<MTLBuffer> buf, uint64_t off, size_t row, size_t img) {
    double s = zelda_texture_scale(c->tex, t);
    if (s == 1) return 0;
    MTLPixelFormat pf, lpf;
    if (zelda_resample_kind(t.pixelFormat, &pf, &lpf) < 0 || !c->r.width || !c->r.height) { zelda_scale_report(2, 0, "buffer to texture copy", NULL, 1, c->tex, s); return 0; }
    MTLRegion dr = zelda_scale_level_region(t, level, s, c->r.xoffset, c->r.yoffset, c->r.width, c->r.height);
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:c->r.width height:c->r.height mipmapped:NO];
    d.storageMode = MTLStorageModePrivate; d.usage = MTLTextureUsageShaderRead;
    for (int z = 0; z < nz; z++) {
        id<MTLTexture> guest = [g_dev newTextureWithDescriptor:d];
        if (!guest) { zelda_scale_report(2, 0, "buffer to texture copy", NULL, 1, c->tex, s); return 0; }
        res_add(guest);
        enc_b_copy_buffer_texture(blit(), buf, off + z * img, row, img, MTLSizeMake(c->r.width, c->r.height, 1), guest, 0, 0, MTLOriginMake(0, 0, 0));
        id<MTLTexture> tmp = zelda_resample(nil, guest, 0, 0, dr.origin.x / s - c->r.xoffset, dr.origin.y / s - c->r.yoffset, 1 / s, dr.size.width, dr.size.height);
        defer_obj_release(guest);
        if (!tmp) { zelda_scale_report(2, 0, "buffer to texture copy", NULL, 1, c->tex, s); return 0; }
        zelda_resample_store(tmp, t, layer0 + c->r.zoffset + z, level, dr.origin);
    }
    zelda_scale_report(2, 1, "buffer to texture copy", NULL, 1, c->tex, s);
    return 1;
}
// CPU read of a scaled 2D texture (the GPU has finished): resampled on an old-queue command buffer and read back.
static int zelda_scaled_read(const tex_t *t, id<MTLTexture> mt, unsigned level, unsigned layer0, const NVNcopyRegion *r, uint8_t *dst, size_t row, size_t img, size_t wb, size_t hb, int nz) {
    double s = zelda_texture_scale(t, mt);
    if (s == 1) return 0;
    id<MTLCommandBuffer> cb = q_cb();
    NSMutableArray<id<MTLTexture>> *tmp = [NSMutableArray array];
    for (int z = 0; z < nz; z++) {
        id<MTLTexture> x = zelda_resample(cb, mt, level, layer0 + r->zoffset + z, r->xoffset * s, r->yoffset * s, s, r->width, r->height);
        if (!x) { zelda_scale_report(3, 0, "CPU texel read", t, s, NULL, 1); return 0; }
        [tmp addObject:x];
    }
    id<MTLBuffer> buf = [g_dev newBufferWithLength:wb * hb * nz options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    for (int z = 0; z < nz; z++)
        [b copyFromTexture:tmp[z] sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(r->width, r->height, 1)
                  toBuffer:buf destinationOffset:z * wb * hb destinationBytesPerRow:wb destinationBytesPerImage:wb * hb];
    [b endEncoding]; [cb commit]; [cb waitUntilCompleted];
    for (int z = 0; z < nz; z++) for (size_t y = 0; y < hb; y++) memcpy(dst + z * img + y * row, (uint8_t *)buf.contents + z * wb * hb + y * wb, wb);
    zelda_scale_report(3, 1, "CPU texel read", t, s, NULL, 1);
    return 1;
}
