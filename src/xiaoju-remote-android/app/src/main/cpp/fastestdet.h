// FastestDet（dog-qiuqiu，BSD 3-Clause）：352×352 输入、80 类（COCO）的小目标检测模型，用 ncnn 跑。
// 安卓（jni.cpp）和电脑上的测试共用这份代码，保证测的就是手机上跑的。
#pragma once
#include <vector>
#include "net.h"

struct Det {
    int cls;        // COCO 类别（0 = 人）
    float score;
    float x1, y1, x2, y2;   // 在原画面里的位置，0…1
};

class FastestDet {
public:
    // param：模型结构（文字）；bin：权重（会拷一份留着，ncnn 直接用这块内存）
    // threads：用几个核（ncnn 要在读模型前定好）
    bool load(const char* param, const unsigned char* bin, size_t len, int threads);
    // 相机的 NV21 画面（w×h）→ 检测结果（按分数从高到低，同类重叠的去掉）
    std::vector<Det> detect(const unsigned char* nv21, int w, int h, float thresh);
    // BGR 图（电脑上测试用）
    std::vector<Det> detectBgr(const unsigned char* bgr, int w, int h, float thresh);

private:
    std::vector<Det> run(ncnn::Mat& in, float thresh);
    ncnn::Net net_;
    std::vector<unsigned char> weights_;
    bool ok_ = false;
};
