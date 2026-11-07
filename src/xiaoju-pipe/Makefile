# 电脑上编译命令行工具（Linux / macOS）。iPhone 的 App 用 ios/project.yml。
#   make            编译 build/ 下的 xjpipe-run、xjpipe-host、xjpipe-worker、gguf-dump
#   make test       跑不需要模型文件的单元测试
#   make e2e        用随机权重的小模型跑主机 + 从机、断线重连（要 python3 + numpy）
CC      ?= cc
CFLAGS  ?= -O3 -Wall -Wno-maybe-uninitialized
CORE    := core/gguf.c core/xj_model.c core/xj_cpu.c core/xj_net.c core/xj_tok.c
UNAME   := $(shell uname)
ifeq ($(UNAME),Darwin)
  # macOS：带上 Metal 后端（和 iPhone 同一份内核），没有 OpenMP
  CORE    += metal/xj_metal.m
  LDLIBS  += -framework Metal -framework Foundation
  CFLAGS  += -fobjc-arc
else
  CFLAGS  += -fopenmp -march=native
  LDLIBS  += -lm -lpthread
endif

TOOLS := xjpipe-run xjpipe-host xjpipe-worker xjpipe-check xjpipe-tok gguf-dump gguf-slice
all: $(addprefix build/,$(TOOLS))

build/%: tools/%.c $(CORE) core/*.h
	@mkdir -p build
	$(CC) $(CFLAGS) -o $@ $< $(CORE) $(LDLIBS)

build/unit: tests/unit.c $(CORE) core/*.h
	@mkdir -p build
	$(CC) $(CFLAGS) -o $@ $< $(CORE) $(LDLIBS)

test: build/unit
	./build/unit

e2e: all
	sh tests/e2e.sh

clean:
	rm -rf build
.PHONY: all test e2e clean
