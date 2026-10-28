// Windowless GPU test of generated alpha-test entries through the production draw/replay path.
// Pixel alpha is .125, .375, .625, .875. A blue background drawn AFTER the red effect must
// appear through rejected fragments: discard must suppress depth writes as well as colour.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;   // dm.h declares them as the host's (loader.c) module list
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } } while (0)

static NvProg *program(id<MTLLibrary> lib, const char *vs, const char *fs, int alpha, uint32_t serial, prog_t *pg) {
    NvProg *p = [NvProg new]; p->sh[0] = [NvShader new]; p->sh[1] = [NvShader new];
    p->sh[0]->fn = [lib newFunctionWithName:@(vs)]; p->sh[1]->fn = [lib newFunctionWithName:@(fs)];
    if (alpha) p->sh[1]->fn_at = [lib newFunctionWithName:@"main0_at"];
    p->sh[1]->stage = 1; p->sh[1]->rf.color_known = 1; p->sh[1]->rf.color_mask = 1;
    snprintf(p->sh[0]->key, sizeof p->sh[0]->key, "%s", vs);
    snprintf(p->sh[1]->key, sizeof p->sh[1]->key, "%s", fs);
    *pg = (prog_t){.serial = serial}; serial_put(serial, p); return p;
}

static void run_case(prog_t *fg, prog_t *bg, unsigned func, float ref, unsigned expected, int split) {
    static uint32_t serial = 99900;
    tex_t t = {.magic = MAGIC('T','E','X',0), .serial = serial++};
    tex_t z = {.magic = MAGIC('T','E','X',0), .serial = serial++};
    t.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8, .width = 4, .height = 1, .depth = 1, .levels = 1, .samples = 1};
    z.d = t.d; z.d.format = NVN_FORMAT_DEPTH32F;
    MTLTextureDescriptor *td = tex_desc(&t, 0); td.storageMode = MTLStorageModeShared;
    id<MTLTexture> target = [g_dev newTextureWithDescriptor:td]; res_add(target);
    mtl_tex_init(&t); serial_put(t.serial, target);
    mtl_tex_init(&z);
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin();
    R.has_rt = 1; R.rt.n = 1; R.rt.color[0] = &t; R.rt.depth = &z;
    R.clear_c[0] = 1; R.cc[0] = MTLClearColorMake(0, 1, 0, 1); R.clear_d = 1; R.cd = 1;
    S.prog = fg; S.poly.cull = NVN_FACE_NONE;
    S.ds.dt = S.ds.dw = 1; S.ds.df = NVN_DEPTH_FUNC_LESS;
    S.color.alpha_func = func;
    p_alpha_ref ar = {ref}; state_op(OP_ALPHA_REF, &ar);
    p_draw d = {.prim = NVN_DRAW_PRIMITIVE_TRIANGLES, .count = 3, .instances = 1};
    if (split) { R.has_sc = 1; R.sc = (p_scissor){0, 0, 2, 1}; }
    draw(&d, NULL);
    if (split) {
        S.color.alpha_func = NVN_ALPHA_FUNC_GREATER; ar.value = .625f; state_op(OP_ALPHA_REF, &ar);
        R.sc = (p_scissor){2, 0, 2, 1}; draw(&d, NULL);
    }
    S.prog = bg; S.color.alpha_func = NVN_ALPHA_FUNC_ALWAYS; R.has_sc = 0; g_pso_dirty = 1;
    draw(&d, NULL);
    uint64_t fence = mtl_sub_commit(); CHECK(mtl_wait(fence, 5000000000ull), "alpha draw completes");
    CHECK(!mtl_last_commit_error(), "alpha draw has no GPU error");
    uint8_t pixels[16]; [target getBytes:pixels bytesPerRow:16 fromRegion:MTLRegionMake2D(0, 0, 4, 1) mipmapLevel:0];
    unsigned red = 0, blue = 0;
    for (int i = 0; i < 4; i++) { if (pixels[4*i] == 255) red |= 1u << i; if (pixels[4*i+2] == 255) blue |= 1u << i; }
    if (red != expected || blue != (15 ^ expected)) fprintf(stderr, "func=%u ref=%g split=%d red=%x blue=%x expected=%x/%x\n", func, ref, split, red, blue, expected, 15 ^ expected);
    CHECK(red == expected, "comparison keeps exactly the expected fragments");
    CHECK(blue == (15 ^ expected), "discarded fragments do not occlude the later background");
    mtl_tex_release(&t); mtl_tex_release(&z);
}

int main(int argc, char **argv) { @autoreleasepool {
    if (argc != 2) { fprintf(stderr, "usage: t_alpha_test generated-alpha.metal\n"); return 2; }
    if (!MTLCreateSystemDefaultDevice()) return 77;
    mtl_init(); NSError *error = nil;
    NSString *source = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:&error];
    id<MTLLibrary> lib = source ? [g_dev newLibraryWithSource:source options:nil error:&error] : nil;
    CHECK(lib != nil, "generated MSL compiles");
    if (!lib) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
    prog_t fg, bg;
    NvProg *keep_fg = program(lib, "near_vertex", "main0", 1, 99701, &fg);
    NvProg *keep_bg = program(lib, "far_vertex", "background", 0, 99702, &bg);
    CHECK(keep_fg->sh[1]->fn_at != nil, "generated alpha entry loads");
    static const unsigned masks[] = {0, 1, 2, 3, 12, 13, 14, 15};
    for (unsigned f = 1; f <= 8; f++) run_case(&fg, &bg, f, .375f, masks[f-1], 0);
    run_case(&fg, &bg, NVN_ALPHA_FUNC_GREATER, .625f, 8, 0);
    run_case(&fg, &bg, NVN_ALPHA_FUNC_LESS, .375f, 9, 1);
    // Alpha enable is part of the pipeline key, while reference and comparison mode are dynamic.
    state_reset(); S.color.alpha_func = NVN_ALPHA_FUNC_ALWAYS;
    uint32_t cf[8] = {MTLPixelFormatRGBA8Unorm}; pso_key a, b, c;
    pso_key_fill(&a, keep_fg->sh[0], keep_fg->sh[1], cf, 0, 0, 1, 0);
    S.color.alpha_func = NVN_ALPHA_FUNC_GREATER;
    pso_key_fill(&b, keep_fg->sh[0], keep_fg->sh[1], cf, 0, 0, 1, 0);
    S.color.alpha_func = NVN_ALPHA_FUNC_LESS; S.alpha_ref = .625f;
    pso_key_fill(&c, keep_fg->sh[0], keep_fg->sh[1], cf, 0, 0, 1, 0);
    CHECK(memcmp(&a, &b, sizeof a) != 0, "alpha enable separates pipelines");
    CHECK(memcmp(&b, &c, sizeof b) == 0, "mode/reference changes reuse the alpha pipeline");
    (void)keep_bg; mtl_drain(); printf("alpha test: %d checks, %d failed\n", checks, failed); return failed != 0;
} }
