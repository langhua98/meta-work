# 模型测速（以后做「认出是不是人」也在这里）：ncnn 是腾讯开源的手机端推理库（BSD 协议）。
# ncnn 自己先编好放在 NCNN_DIR（见 scripts/build-ncnn-android.sh），这里只链接它。
cmake_minimum_required(VERSION 3.10)
project(xjbench CXX)

set(ncnn_DIR ${NCNN_DIR}/lib/cmake/ncnn)
find_package(ncnn REQUIRED)

add_library(xjbench SHARED bench.cpp fastestdet.cpp detector_jni.cpp)
target_link_libraries(xjbench ncnn log)
# 去掉调试符号，安装包小一点
set_target_properties(xjbench PROPERTIES LINK_FLAGS "-s")
