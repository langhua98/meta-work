// 照着 FastestDet 官方的 ncnn 例子（example/ncnn/FastestDet.cpp）写的：输入 BGR、0…1，
// 输出 22×22 格，每格 [前景, x 偏移, y 偏移, 宽, 高, 80 类]，分数 = 类别^0.4 × 前景^0.6，再按类去重（见 same()）。
#include "fastestdet.h"

#include <math.h>
#include <string.h>
#include <algorithm>

#include "mat.h"

namespace {
const int kInput = 352;
const int kClasses = 80;

float sigmoid(float x) { return 1.0f / (1.0f + expf(-x)); }
float tanhf2(float x) { return 2.0f / (1.0f + expf(-2 * x)) - 1; }

// 同一个东西的两个框：重叠多（IoU > 0.45），或者小的那个大部分（80%）在大的里面
// （模型常给一个人同时出全身框和半身框，只按 IoU 去不掉，「人×2」就数错了）
bool same(const Det& a, const Det& b) {
    float iw = std::min(a.x2, b.x2) - std::max(a.x1, b.x1);
    float ih = std::min(a.y2, b.y2) - std::max(a.y1, b.y1);
    if (iw <= 0 || ih <= 0) return false;
    float inter = iw * ih;
    float sa = (a.x2 - a.x1) * (a.y2 - a.y1), sb = (b.x2 - b.x1) * (b.y2 - b.y1);
    float u = sa + sb - inter;
    if (u > 0 && inter / u > 0.45f) return true;
    float small = std::min(sa, sb);
    return small > 0 && inter / small > 0.8f;
}
}  // namespace

bool FastestDet::load(const char* param, const unsigned char* bin, size_t len, int threads) {
    net_.opt.num_threads = threads;
    net_.opt.lightmode = true;
    net_.opt.use_vulkan_compute = false;
    if (net_.load_param_mem(param) != 0) return false;
    weights_.assign(bin, bin + len);
    int used = net_.load_model(weights_.data());
    ok_ = used > 0;
    return ok_;
}

std::vector<Det> FastestDet::detect(const unsigned char* nv21, int w, int h, float thresh) {
    if (!ok_) return {};
    // NV21 → RGB → 缩到 352×352 并换成 BGR（模型是用 OpenCV 读的 BGR 图训练的）
    std::vector<unsigned char> rgb((size_t)w * h * 3);
    ncnn::yuv420sp2rgb(nv21, w, h, rgb.data());
    ncnn::Mat in = ncnn::Mat::from_pixels_resize(rgb.data(), ncnn::Mat::PIXEL_RGB2BGR, w, h, kInput, kInput);
    return run(in, thresh);
}

std::vector<Det> FastestDet::detectBgr(const unsigned char* bgr, int w, int h, float thresh) {
    if (!ok_) return {};
    ncnn::Mat in = ncnn::Mat::from_pixels_resize(bgr, ncnn::Mat::PIXEL_BGR, w, h, kInput, kInput);
    return run(in, thresh);
}

std::vector<Det> FastestDet::run(ncnn::Mat& in, float thresh) {
    const float mean[3] = {0.f, 0.f, 0.f};
    const float norm[3] = {1 / 255.f, 1 / 255.f, 1 / 255.f};
    in.substract_mean_normalize(mean, norm);

    ncnn::Extractor ex = net_.create_extractor();
    ex.input("input.1", in);
    ncnn::Mat out;
    if (ex.extract("758", out) != 0 || out.empty()) return {};

    const int gw = out.w, gh = out.h;
    // ncnn 的 Mat 每个通道之间可能有对齐空隙，按 channel() 取
    auto at = [&](int c, int y, int x) { return out.channel(c).row(y)[x]; };

    std::vector<Det> boxes;
    for (int y = 0; y < gh; y++) {
        for (int x = 0; x < gw; x++) {
            float obj = at(0, y, x);
            int cls = 0;
            float best = 0;
            for (int c = 0; c < kClasses && 5 + c < out.c; c++) {
                float s = at(5 + c, y, x);
                if (s > best) { best = s; cls = c; }
            }
            float score = powf(best, 0.4f) * powf(obj, 0.6f);
            if (!(score > thresh)) continue;
            float cx = (x + tanhf2(at(1, y, x))) / gw;
            float cy = (y + tanhf2(at(2, y, x))) / gh;
            float bw = sigmoid(at(3, y, x));
            float bh = sigmoid(at(4, y, x));
            Det d;
            d.cls = cls; d.score = score;
            d.x1 = std::max(0.f, cx - bw / 2); d.y1 = std::max(0.f, cy - bh / 2);
            d.x2 = std::min(1.f, cx + bw / 2); d.y2 = std::min(1.f, cy + bh / 2);
            boxes.push_back(d);
        }
    }
    std::sort(boxes.begin(), boxes.end(), [](const Det& a, const Det& b) { return a.score > b.score; });
    std::vector<Det> kept;
    for (const Det& b : boxes) {
        bool dup = false;
        for (const Det& k : kept) if (k.cls == b.cls && same(k, b)) { dup = true; break; }
        if (!dup) kept.push_back(b);
    }
    return kept;
}
