// 模型测速：在这台手机上跑一个 ncnn 模型，量每次推理多少毫秒。
// 只测速度：权重全用 0（和 ncnn 自带的 benchncnn 一样），速度和真权重一样；认得准不准在电脑上用真权重测。
#include <jni.h>
#include <string.h>
#include <float.h>
#include <vector>

#include "net.h"
#include "datareader.h"
#include "benchmark.h"
#include "cpu.h"

namespace {

class DataReaderFromEmpty : public ncnn::DataReader {
public:
    int scan(const char*, void*) const override { return 0; }
    size_t read(void* buf, size_t size) const override { memset(buf, 0, size); return size; }
};

}  // namespace

// 返回 [最快, 平均, 最慢, 跑了几次]（毫秒）；模型读不进来返回 null。
// threads：用几个核；budgetMs：最多测多久（至少跑 3 次）；maxLoops：最多跑几次。
extern "C" JNIEXPORT jfloatArray JNICALL
Java_com_langhua98_xiaoju_remote_NativeBench_run(JNIEnv* env, jclass, jstring jparam, jint w, jint h,
                                                 jint threads, jint budgetMs, jint maxLoops) {
    ncnn::UnlockedPoolAllocator blobs;
    ncnn::PoolAllocator workspace;
    ncnn::Net net;
    net.opt.num_threads = threads;
    net.opt.use_vulkan_compute = false;
    net.opt.lightmode = true;
    net.opt.blob_allocator = &blobs;
    net.opt.workspace_allocator = &workspace;

    const char* param = env->GetStringUTFChars(jparam, nullptr);
    int r = net.load_param_mem(param);
    env->ReleaseStringUTFChars(jparam, param);
    if (r != 0) return nullptr;
    DataReaderFromEmpty dr;
    net.load_model(dr);

    const std::vector<const char*>& inputs = net.input_names();
    const std::vector<const char*>& outputs = net.output_names();
    if (inputs.empty() || outputs.empty()) return nullptr;
    ncnn::Mat in(w, h, 3);
    in.fill(0.01f);

    auto once = [&]() {
        ncnn::Extractor ex = net.create_extractor();
        ex.input(inputs[0], in);
        for (const char* name : outputs) {
            ncnn::Mat out;
            ex.extract(name, out);
        }
    };

    // 预热两次（第一次要分配内存、选算法，不算）
    once();
    once();

    double best = DBL_MAX, worst = 0, sum = 0;
    int n = 0;
    double start = ncnn::get_current_time();
    while (n < maxLoops && (n < 3 || ncnn::get_current_time() - start < budgetMs)) {
        double t0 = ncnn::get_current_time();
        once();
        double dt = ncnn::get_current_time() - t0;
        if (dt < best) best = dt;
        if (dt > worst) worst = dt;
        sum += dt;
        n++;
    }
    float res[4] = {(float)best, (float)(sum / n), (float)worst, (float)n};
    jfloatArray a = env->NewFloatArray(4);
    env->SetFloatArrayRegion(a, 0, 4, res);
    return a;
}

// CPU 有几个核（ncnn 自己数的）
extern "C" JNIEXPORT jint JNICALL
Java_com_langhua98_xiaoju_remote_NativeBench_cpuCount(JNIEnv*, jclass) {
    return ncnn::get_cpu_count();
}
