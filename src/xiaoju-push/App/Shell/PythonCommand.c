// python3 命令：ios_system 按 commandDictionary.plist 里的 MAIN / xiaoju_python3_main 找到这里来跑。
// Python 本身是 BeeWare 打包的官方 CPython（Python.xcframework，PSF 许可），只嵌进 App、不链接，用到时才 dlopen。
// 不 include Python 的头文件，用到的两个函数自己声明。
//
// ios_system 里的命令各写各的 thread_stdout，Python 不认识它，只会往 1、2 号文件描述符写。
// 所以跑之前把 0/1/2 临时指到这条命令的输入输出上，跑完换回来（一次只跑一个 Python，用锁保证）。

#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

extern __thread FILE *thread_stdin;
extern __thread FILE *thread_stdout;
extern __thread FILE *thread_stderr;

typedef int (*py_bytes_main)(int, char **);

static pthread_mutex_t running = PTHREAD_MUTEX_INITIALIZER;

static int run_python(int argc, char **argv) {
    const char *lib = getenv("XIAOJU_PYTHON_LIB");
    void *h = lib ? dlopen(lib, RTLD_NOW | RTLD_GLOBAL) : NULL;
    py_bytes_main run = h ? (py_bytes_main)dlsym(h, "Py_BytesMain") : NULL;
    if (!run) {
        fprintf(thread_stderr, "python3: 这个版本的 App 里没有 Python（%s）\n", h ? "找不到 Py_BytesMain" : dlerror());
        return 127;
    }
    if (pthread_mutex_trylock(&running) != 0) {
        fprintf(thread_stderr, "python3: 已经有一个 Python 在跑，等它结束再试\n");
        return 1;
    }
    fflush(stdout);
    fflush(stderr);
    fflush(thread_stdout);
    fflush(thread_stderr);
    int saved[3] = {dup(0), dup(1), dup(2)};
    if (thread_stdin) dup2(fileno(thread_stdin), 0);
    dup2(fileno(thread_stdout), 1);
    dup2(fileno(thread_stderr), 2);

    int status = run(argc, argv);

    fflush(stdout);
    fflush(stderr);
    for (int i = 0; i < 3; i++) {
        if (saved[i] >= 0) { dup2(saved[i], i); close(saved[i]); }
    }
    pthread_mutex_unlock(&running);
    return status;
}

__attribute__((used, visibility("default")))
int xiaoju_python3_main(int argc, char **argv) { return run_python(argc, argv); }

/// 在原参数前面插几个参数再交给 Python：pip → python3 -m pip …，sqlite3 → python3 -m sqlite3 …
static int run_module(int argc, char **argv, const char *module) {
    char **args = calloc((size_t)argc + 3, sizeof(char *));
    if (!args) return 1;
    args[0] = "python3"; args[1] = "-m"; args[2] = (char *)module;
    for (int i = 1; i < argc; i++) args[i + 2] = argv[i];
    int status = run_python(argc + 2, args);
    free(args);
    return status;
}

/// pip / pip3：只装纯 Python 的包，装到 PIP_TARGET（ShellRunner 里设好，也在 PYTHONPATH 里）
__attribute__((used, visibility("default")))
int xiaoju_pip_main(int argc, char **argv) { return run_module(argc, argv, "pip"); }

/// sqlite3：用 Python 自带的 sqlite3 命令行（python3 -m sqlite3 数据库 "SQL"）
__attribute__((used, visibility("default")))
int xiaoju_sqlite3_main(int argc, char **argv) { return run_module(argc, argv, "sqlite3"); }

/// 给 Swift 写的命令（node）用：这条命令的输入输出
__attribute__((used, visibility("default"))) FILE *xiaoju_thread_stdout(void) { return thread_stdout; }
__attribute__((used, visibility("default"))) FILE *xiaoju_thread_stderr(void) { return thread_stderr; }

/// 让正在跑的 Python 停下（和按 Ctrl-C 一样，抛 KeyboardInterrupt）。没在跑就什么都不做。返回 1 表示发出去了。
__attribute__((used, visibility("default")))
int xiaoju_python3_interrupt(void) {
    if (pthread_mutex_trylock(&running) == 0) { pthread_mutex_unlock(&running); return 0; }
    void (*interrupt)(void) = (void (*)(void))dlsym(RTLD_DEFAULT, "PyErr_SetInterrupt");
    if (!interrupt) return 0;
    interrupt();
    return 1;
}
