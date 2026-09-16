/*
 * JDBC「进程内 JVM」可行性探针（native child process 入口）。
 *
 * 在 appspawn 起的子进程里依次测三件事，结果写进传入的 fd（父进程读走）：
 *   1. 沙箱里的 .so 能不能 dlopen —— 决定"下载来的 JRE / 原生 agent 能不能加载"。
 *      （对照：execve 一个未签名的沙箱 ELF 会被 BinSec 拒，§12；dlopen 是另一条路。）
 *   2. JIT 需要的能力：mmap(PROT_EXEC) / mmap(RW)+mprotect(RX) / 真的跳进去执行。
 *      OHOS 上写可执行内存可能被 code_protect 拦（这也是 JVM 必须 -Xint 的原因）。
 *   3. 给定的 libjvm.so 能否 dlopen + 拿到 JNI_CreateJavaVM（能的话就顺手建个 JVM）。
 *
 * entryParams 是分号分隔的路径表："<沙箱里的musl探针.so>;<libjvm.so>;<jvm选项>"
 * 任一段可以为空。结果是一行 JSON，写到 fdList 的第一个 fd。
 */
#include <stdbool.h>
#include <AbilityKit/native_child_process.h>
#include <hilog/log.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#undef LOG_DOMAIN
#define LOG_DOMAIN 0xDB3
#undef LOG_TAG
#define LOG_TAG "DBX_NCP"

/*
 * 附带的 glibc 检查需要手动准备：把 dbx 下载的 JRE 里的 lib/libjli.so 拷成
 * entry/libs/arm64-v8a/libdbx_jli.so（146KB），探针会 dlopen 它并报出 libc 依赖
 * 错误（`Error loading shared library ld-linux-aarch64.so.1`）。该文件是诊断用，
 * 不随仓库/长期 HAP 保留 —— 证据见 docs/ohos-agent-exec-denied.md §15.3。
 */

/* 最小 JNI 声明（不依赖 jni.h，NDK sysroot 里不一定有） */
typedef struct JavaVMOption {
    char *optionString;
    void *extraInfo;
} JavaVMOption;
typedef struct JavaVMInitArgs {
    int32_t version;
    int32_t nOptions;
    JavaVMOption *options;
    int8_t ignoreUnrecognized;
} JavaVMInitArgs;
typedef int32_t (*JNI_CreateJavaVM_fn)(void **pvm, void **penv, void *args);
#define DBX_JNI_VERSION_1_8 0x00010008

typedef struct {
    char sandbox_lib[256];
    char jvm_lib[256];
    char jvm_options[256];
    char bundle_lib[256];
} probe_params;

static char g_result[4096];
static size_t g_result_len;

static void result_printf(const char *fmt, ...)
{
    va_list args;
    va_start(args, fmt);
    int written = vsnprintf(g_result + g_result_len, sizeof(g_result) - g_result_len, fmt, args);
    va_end(args);
    if (written > 0 && (size_t)written < sizeof(g_result) - g_result_len) {
        g_result_len += (size_t)written;
    }
}

static void parse_params(const char *raw, probe_params *out)
{
    memset(out, 0, sizeof(*out));
    if (raw == NULL) {
        return;
    }
    const char *p = raw;
    char *fields[4] = { out->sandbox_lib, out->jvm_lib, out->jvm_options, out->bundle_lib };
    const size_t caps[4] = { sizeof(out->sandbox_lib), sizeof(out->jvm_lib), sizeof(out->jvm_options),
                             sizeof(out->bundle_lib) };
    for (int i = 0; i < 4 && p != NULL; i++) {
        const char *sep = strchr(p, ';');
        size_t len = sep != NULL ? (size_t)(sep - p) : strlen(p);
        if (len >= caps[i]) {
            len = caps[i] - 1;
        }
        memcpy(fields[i], p, len);
        fields[i][len] = '\0';
        p = sep != NULL ? sep + 1 : NULL;
    }
}

/* 返回 0 表示成功 */
static int test_dlopen(const char *label, const char *path, const char *symbol, bool *symbol_found)
{
    if (symbol_found != NULL) {
        *symbol_found = false;
    }
    if (path == NULL || path[0] == '\0') {
        OH_LOG_INFO(LOG_APP, "JVM_PROBE %{public}s: skipped (no path)", label);
        return -1;
    }
    void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (handle == NULL) {
        OH_LOG_INFO(LOG_APP, "JVM_PROBE %{public}s: FAIL %{public}s", label, dlerror());
        return -1;
    }
    OH_LOG_INFO(LOG_APP, "JVM_PROBE %{public}s: dlopen OK", label);
    if (symbol != NULL && symbol_found != NULL) {
        *symbol_found = dlsym(handle, symbol) != NULL;
    }
    return 0;
}

/* 文件-backed 的 PROT_EXEC 映射：dlopen 内部就是这一步 */
static void test_file_exec_mmap(const char *label, const char *path)
{
    if (path == NULL || path[0] == '\0') {
        return;
    }
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        result_printf("\"%s\":\"open FAIL errno=%d\",", label, errno);
        return;
    }
    void *p = mmap(NULL, 4096, PROT_READ | PROT_EXEC, MAP_PRIVATE, fd, 0);
    if (p == MAP_FAILED) {
        result_printf("\"%s\":\"mmap exec FAIL errno=%d\",", label, errno);
        OH_LOG_INFO(LOG_APP, "JVM_PROBE %{public}s file exec mmap FAIL errno=%{public}d", label, errno);
    } else {
        result_printf("\"%s\":\"OK\",", label);
        munmap(p, 4096);
    }
    close(fd);
}

/* 写一段 AArch64 `ret` 并真的跳进去，验证"可写可执行内存" */
static void test_jit(void)
{
    void *rwx = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (rwx == MAP_FAILED) {
        result_printf("\"mmap_rwx\":\"FAIL errno=%d\",", errno);
        OH_LOG_INFO(LOG_APP, "JVM_PROBE jit: mmap RWX FAIL errno=%{public}d", errno);
    } else {
        result_printf("\"mmap_rwx\":\"OK\",");
        OH_LOG_INFO(LOG_APP, "JVM_PROBE jit: mmap RWX OK");
        munmap(rwx, 4096);
    }

    /* 匿名 RX（只读可执行）单独测一下，区分"禁止 W+X"还是"禁止一切匿名可执行" */
    void *rx = mmap(NULL, 4096, PROT_READ | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (rx == MAP_FAILED) {
        result_printf("\"mmap_rx_anon\":\"FAIL errno=%d\",", errno);
        OH_LOG_INFO(LOG_APP, "JVM_PROBE jit: mmap RX FAIL errno=%{public}d", errno);
    } else {
        result_printf("\"mmap_rx_anon\":\"OK\",");
        munmap(rx, 4096);
    }
    /* RW -> RWX 的 mprotect（有些实现只拦"加执行"这一步） */
    void *rwx2 = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (rwx2 != MAP_FAILED) {
        int rc = mprotect(rwx2, 4096, PROT_READ | PROT_WRITE | PROT_EXEC);
        if (rc == 0) {
            result_printf("\"mprotect_rwx\":\"OK\",");
        } else {
            result_printf("\"mprotect_rwx\":\"FAIL errno=%d\",", errno);
        }
        munmap(rwx2, 4096);
    }

    /* JIT 的真实形态：先 RW 写码，再 mprotect 成 RX 执行 */
    void *rw = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (rw == MAP_FAILED) {
        result_printf("\"mmap_rw\":\"FAIL errno=%d\",", errno);
        return;
    }
    result_printf("\"mmap_rw\":\"OK\",");
    uint32_t *code = (uint32_t *)rw;
    code[0] = 0x52800540u; /* mov w0, #42 */
    code[1] = 0xd65f03c0u; /* ret */
    __builtin___clear_cache((char *)rw, (char *)rw + 8);

    if (mprotect(rw, 4096, PROT_READ | PROT_EXEC) != 0) {
        result_printf("\"mprotect_rx\":\"FAIL errno=%d\",", errno);
        OH_LOG_INFO(LOG_APP, "JVM_PROBE jit: mprotect RX FAIL errno=%{public}d", errno);
        munmap(rw, 4096);
        return;
    }
    result_printf("\"mprotect_rx\":\"OK\",");
    int (*fn)(void) = (int (*)(void))rw;
    int value = fn();
    result_printf("\"exec_result\":%d,", value);
    OH_LOG_INFO(LOG_APP, "JVM_PROBE jit: exec RX OK value=%{public}d", value);
    munmap(rw, 4096);
}

static void test_jvm(const probe_params *params)
{
    if (params->jvm_lib[0] == '\0') {
        result_printf("\"libjvm\":\"skipped\",");
        return;
    }
    void *handle = dlopen(params->jvm_lib, RTLD_NOW | RTLD_LOCAL);
    if (handle == NULL) {
        result_printf("\"libjvm\":\"FAIL %s\",", dlerror());
        return;
    }
    JNI_CreateJavaVM_fn create = (JNI_CreateJavaVM_fn)dlsym(handle, "JNI_CreateJavaVM");
    if (create == NULL) {
        result_printf("\"libjvm\":\"dlopen OK but no JNI_CreateJavaVM\",");
        return;
    }
    result_printf("\"libjvm\":\"OK\",\"create_vm_symbol\":\"OK\",");
    if (params->jvm_options[0] == '\0') {
        return;
    }
    JavaVMOption option;
    option.optionString = (char *)params->jvm_options;
    option.extraInfo = NULL;
    JavaVMInitArgs init_args;
    memset(&init_args, 0, sizeof(init_args));
    init_args.version = DBX_JNI_VERSION_1_8;
    init_args.nOptions = 1;
    init_args.options = &option;
    init_args.ignoreUnrecognized = 1;
    void *vm = NULL;
    void *env = NULL;
    int32_t rc = create(&vm, &env, &init_args);
    result_printf("\"create_vm_rc\":%d,", rc);
    OH_LOG_INFO(LOG_APP, "JVM_PROBE create JVM rc=%{public}d", rc);
}

/* 子进程自检：确认沙箱里那份文件确实是完整的 ELF（排除"ArkTS 拷贝坏了"这种解释） */
static void inspect_sandbox_file(const char *path)
{
    if (path == NULL || path[0] == '\0') {
        result_printf("\"sandbox_file\":\"skipped\",");
        return;
    }
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        result_printf("\"sandbox_file\":\"open FAIL errno=%d\",", errno);
        return;
    }
    unsigned char head[8] = { 0 };
    ssize_t got = read(fd, head, sizeof(head));
    off_t size = lseek(fd, 0, SEEK_END);
    close(fd);
    bool elf = got == 8 && head[0] == 0x7f && head[1] == 'E' && head[2] == 'L' && head[3] == 'F';
    result_printf("\"sandbox_file\":\"%s\",\"sandbox_file_size\":%ld,", elf ? "ELF_OK" : "NOT_ELF", (long)size);
    OH_LOG_INFO(LOG_APP, "JVM_PROBE sandbox file elf=%{public}d size=%{public}ld", elf ? 1 : 0, (long)size);
}

void Main(NativeChildProcess_Args args)
{
    probe_params params;
    parse_params(args.entryParams, &params);
    OH_LOG_INFO(LOG_APP, "JVM_PROBE start sandbox=%{public}s jvm=%{public}s",
        params.sandbox_lib[0] != '\0' ? params.sandbox_lib : "(none)",
        params.jvm_lib[0] != '\0' ? params.jvm_lib : "(none)");

    result_printf("{");
    /* 0. 拷贝完整性 + 对照：dlopen 我们自己的 bundle 路径（必然允许） */
    inspect_sandbox_file(params.sandbox_lib);
    Dl_info self_info;
    if (dladdr((void *)Main, &self_info) != 0 && self_info.dli_fname != NULL) {
        void *self = dlopen(self_info.dli_fname, RTLD_NOW | RTLD_LOCAL);
        result_printf("\"bundle_dlopen\":\"%s\",\"bundle_path\":\"%s\",",
            self != NULL ? "OK" : "FAIL", self_info.dli_fname);
        if (self != NULL) {
            dlclose(self);
        } else {
            OH_LOG_INFO(LOG_APP, "JVM_PROBE bundle control FAIL %{public}s", dlerror());
        }
    }
    /* 1. 沙箱里的 musl .so（对照组：证明"沙箱 dlopen"本身是否被允许） */
    bool marker = false;
    int sandbox_rc = test_dlopen("sandbox_musl", params.sandbox_lib, "ncp_sandbox_marker", &marker);
    if (sandbox_rc != 0 && params.sandbox_lib[0] != '\0') {
        /* 再看一次 RTLD_LAZY：区分"加载就被拒"与"解析符号失败" */
        void *lazy = dlopen(params.sandbox_lib, RTLD_LAZY | RTLD_LOCAL);
        result_printf("\"sandbox_dlopen_lazy\":\"%s\",", lazy != NULL ? "OK" : "FAIL");
        if (lazy != NULL) {
            dlclose(lazy);
        } else {
            OH_LOG_INFO(LOG_APP, "JVM_PROBE sandbox_musl lazy: FAIL %{public}s", dlerror());
        }
    }
    result_printf("\"sandbox_dlopen\":\"%s\",\"sandbox_symbol\":%s,",
        sandbox_rc == 0 ? "OK" : "FAIL", marker ? "true" : "false");
    /* 2a. 文件-backed exec 映射：沙箱文件 vs bundle 文件 */
    test_file_exec_mmap("exec_mmap_sandbox", params.sandbox_lib);
    if (dladdr((void *)Main, &self_info) != 0 && self_info.dli_fname != NULL) {
        test_file_exec_mmap("exec_mmap_bundle", self_info.dli_fname);
        /* 2b. bundle 里的 glibc 库（JRE 的 libjli.so 拷进来的）：验证 libc 依赖 */
        char jli[512];
        snprintf(jli, sizeof(jli), "%s", self_info.dli_fname);
        char *slash = strrchr(jli, '/');
        if (slash != NULL) {
            snprintf(slash + 1, sizeof(jli) - (size_t)(slash + 1 - jli), "libdbx_jli.so");
            bool unused = false;
            int rc = test_dlopen("bundle_glibc_libjli", jli, NULL, &unused);
            result_printf("\"bundle_glibc_libjli_ok\":%s,", rc == 0 ? "true" : "false");
        }
    }
    /* 2c. JIT 内存 */
    test_jit();
    /* 3. libjvm.so */
    test_jvm(&params);
    result_printf("\"done\":true}\n");

    OH_LOG_INFO(LOG_APP, "JVM_PROBE result=%{public}s", g_result);
    for (NativeChildProcess_Fd *fd = args.fdList.head; fd != NULL; fd = fd->next) {
        ssize_t written = write(fd->fd, g_result, g_result_len);
        OH_LOG_INFO(LOG_APP, "JVM_PROBE fd name=%{public}s written=%{public}d",
            fd->fdName != NULL ? fd->fdName : "(null)", (int)written);
    }
}
