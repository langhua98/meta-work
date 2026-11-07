// 给 Kotlin（ObjectDetector.kt）用的物体识别：FastestDet，一个核、后台慢慢跑。
#include <jni.h>
#include <mutex>
#include <vector>

#include "fastestdet.h"

namespace {
FastestDet* g_det = nullptr;
std::mutex g_mu;   // 同一时间只跑一个（老手机，省着点）
}  // namespace

extern "C" JNIEXPORT jboolean JNICALL
Java_com_langhua98_xiaoju_remote_ObjectDetector_nativeLoad(JNIEnv* env, jclass, jstring jparam, jbyteArray jbin) {
    std::lock_guard<std::mutex> lock(g_mu);
    if (g_det) return JNI_TRUE;
    const char* param = env->GetStringUTFChars(jparam, nullptr);
    jsize n = env->GetArrayLength(jbin);
    std::vector<unsigned char> bin(n);
    env->GetByteArrayRegion(jbin, 0, n, reinterpret_cast<jbyte*>(bin.data()));
    FastestDet* d = new FastestDet();
    bool ok = d->load(param, bin.data(), bin.size(), 1);
    env->ReleaseStringUTFChars(jparam, param);
    if (!ok) { delete d; return JNI_FALSE; }
    g_det = d;
    return JNI_TRUE;
}

// 返回 [类别, 分数, x1, y1, x2, y2] × n（位置是 0…1，相机原始方向）
extern "C" JNIEXPORT jfloatArray JNICALL
Java_com_langhua98_xiaoju_remote_ObjectDetector_nativeDetect(JNIEnv* env, jclass, jbyteArray jnv21, jint w, jint h, jfloat thresh) {
    std::lock_guard<std::mutex> lock(g_mu);
    if (!g_det) return nullptr;
    jsize n = env->GetArrayLength(jnv21);
    if (n < w * h * 3 / 2) return nullptr;
    std::vector<unsigned char> nv21(n);
    env->GetByteArrayRegion(jnv21, 0, n, reinterpret_cast<jbyte*>(nv21.data()));
    std::vector<Det> r = g_det->detect(nv21.data(), w, h, thresh);
    std::vector<float> out;
    out.reserve(r.size() * 6);
    for (const Det& d : r) {
        out.push_back((float)d.cls); out.push_back(d.score);
        out.push_back(d.x1); out.push_back(d.y1); out.push_back(d.x2); out.push_back(d.y2);
    }
    jfloatArray a = env->NewFloatArray((jsize)out.size());
    env->SetFloatArrayRegion(a, 0, (jsize)out.size(), out.data());
    return a;
}
