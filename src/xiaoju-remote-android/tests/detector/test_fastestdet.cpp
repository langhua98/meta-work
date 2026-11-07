// 在电脑上跑手机用的同一份 fastestdet.cpp（和 assets 里同一个模型），看认得对不对。
// 用法：test_fastestdet 模型.param 模型.bin 图.raw 期望类别 [期望类别…]
// 期望类别写成「0x2」表示这一类正好要认出 2 个（同一个东西不能数两次，两个人也不能并成一个）。
// 图.raw 由 make_inputs.py 生成。BGR 和 NV21 两条路都认一遍，都要认出期望的类别。
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <string>
#include <vector>

#include "fastestdet.h"

static std::vector<unsigned char> readAll(const char* path) {
    std::vector<unsigned char> d;
    FILE* f = fopen(path, "rb");
    if (!f) return d;
    unsigned char buf[65536];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, f)) > 0) d.insert(d.end(), buf, buf + n);
    fclose(f);
    return d;
}

struct Want { int cls; int count; };   // count = 0：至少一个就行

static bool check(const char* what, const std::vector<Det>& ds, const std::vector<Want>& want) {
    printf("  %s：%zu 个\n", what, ds.size());
    for (const Det& d : ds)
        printf("    类别 %2d  分数 %.2f  框 [%.2f %.2f %.2f %.2f]\n", d.cls, d.score, d.x1, d.y1, d.x2, d.y2);
    bool ok = true;
    for (const Want& wt : want) {
        int n = 0;
        for (const Det& d : ds) n += d.cls == wt.cls;
        if (n == 0) { printf("  ✗ 没认出类别 %d\n", wt.cls); ok = false; }
        else if (wt.count > 0 && n != wt.count) { printf("  ✗ 类别 %d 要 %d 个，认出 %d 个\n", wt.cls, wt.count, n); ok = false; }
    }
    for (const Det& d : ds)
        if (!(d.x1 >= 0 && d.y1 >= 0 && d.x2 <= 1 && d.y2 <= 1 && d.x1 < d.x2 && d.y1 < d.y2)) {
            printf("  ✗ 框不对\n"); ok = false;
        }
    return ok;
}

int main(int argc, char** argv) {
    if (argc < 5) { fprintf(stderr, "用法：%s param bin 图.raw 期望类别...\n", argv[0]); return 2; }
    std::vector<unsigned char> param = readAll(argv[1]), bin = readAll(argv[2]), img = readAll(argv[3]);
    if (param.empty() || bin.empty() || img.size() < 8) { fprintf(stderr, "读不了文件\n"); return 2; }
    param.push_back(0);
    std::vector<Want> want;
    for (int i = 4; i < argc; i++) {
        Want wt = {atoi(argv[i]), 0};
        const char* x = strchr(argv[i], 'x');
        if (x) wt.count = atoi(x + 1);
        want.push_back(wt);
    }

    int w = *(int*)&img[0], h = *(int*)&img[4];
    const unsigned char* bgr = &img[8];
    const unsigned char* nv21 = bgr + (size_t)w * h * 3;
    if (img.size() < 8 + (size_t)w * h * 3 + (size_t)w * h * 3 / 2) { fprintf(stderr, "图不完整\n"); return 2; }

    FastestDet det;
    if (!det.load((const char*)param.data(), bin.data(), bin.size(), 1)) { printf("✗ 读不了模型\n"); return 1; }
    printf("%s（%d×%d）\n", argv[3], w, h);
    bool ok = check("BGR", det.detectBgr(bgr, w, h, 0.55f), want);
    ok &= check("NV21（手机相机的格式）", det.detect(nv21, w, h, 0.55f), want);
    printf(ok ? "  通过\n" : "  ✗ 不通过\n");
    return ok ? 0 : 1;
}
