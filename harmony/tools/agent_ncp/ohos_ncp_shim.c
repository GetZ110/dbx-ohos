//go:build ohos_ncp

/*
 * OHOS native child process 的入口函数。
 *
 * 入口签名由系统固定为 `void Main(NativeChildProcess_Args args)`；子进程由
 * appspawn 通过 dlopen 加载本 .so（不经过 execve，因此不需要文件的执行位，
 * 也不需要代码签名身份）。
 *
 * 这里只做一件事：把父进程通过 fdList 传进来的 fd 复制到 0/1，
 * 让 Go 侧原有的 stdin/stdout JSON-RPC 循环直接跑在传入的通道上。
 *
 * 两种约定都支持：
 *   - 单 fd（socketpair / 双向管道）：该 fd 同时当 stdin 与 stdout；
 *   - 双 fd：名字为 in/stdin 的当 stdin，out/stdout 的当 stdout，
 *     未命名时按 fdList 顺序取前两个。
 */
#include <stdbool.h>
#include <AbilityKit/native_child_process.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>

/* 由 ohos_ncp.go 用 //export 导出 */
extern void dbxAgentRun(void);

/*
 * 运行时 g 的按线程存储。
 *
 * Linux/arm64 的 Go 运行时把 g 存在 TLS 里（runtime.load_g/save_g 走
 * initial-exec 模型）。musl 只给 dlopen 进来的模块分配动态 TLS，解析不了 IE
 * 重定位，dlopen 会直接失败：
 *   Error relocating libX.so: initial-exec TLS resolves to dynamic definition
 * 所以 Go 运行时的 load_g/save_g 被补丁改成调这两个函数（见
 * harmony/tools/go_ohos_overlay.py），这里用 C 的 __thread 走动态 TLS。
 *
 * 注意 OHOS 的 clang 默认就是 emulated TLS（-femulated-tls），也就是走
 * compiler-rt 的 __emutls_get_address + pthread key —— 平台自己的选择，正因为
 * OHOS 的 musl 既不支持 TLSDESC、也不接受 dlopen 模块的 IE TLS。
 */
static __thread void *dbx_go_g;

void *dbxLoadG(void)
{
    return dbx_go_g;
}

void dbxSaveG(void *g)
{
    dbx_go_g = g;
}

static int name_is(const char *name, const char *a, const char *b)
{
    if (name == NULL) {
        return 0;
    }
    return strcmp(name, a) == 0 || strcmp(name, b) == 0;
}

/* 挪到 >= 3 的 fd 上，避免后面 dup2 互相覆盖 */
static int move_above_std(int fd)
{
    if (fd > 2) {
        return fd;
    }
    return fcntl(fd, F_DUPFD, 3);
}

__attribute__((visibility("default")))
void Main(NativeChildProcess_Args args)
{
    int in_fd = -1;
    int out_fd = -1;
    int idx = 0;

    for (NativeChildProcess_Fd *f = args.fdList.head; f != NULL; f = f->next, idx++) {
        if (name_is(f->fdName, "in", "stdin")) {
            in_fd = f->fd;
        } else if (name_is(f->fdName, "out", "stdout")) {
            out_fd = f->fd;
        } else if (idx == 0 && in_fd < 0) {
            in_fd = f->fd;
        } else if (idx == 1 && out_fd < 0) {
            out_fd = f->fd;
        }
    }
    if (in_fd < 0) {
        in_fd = out_fd;
    }
    if (out_fd < 0) {
        out_fd = in_fd;
    }

    int saved_in = -1;
    int saved_out = -1;
    if (in_fd >= 0) {
        saved_in = move_above_std(in_fd);
    }
    if (out_fd >= 0) {
        saved_out = move_above_std(out_fd);
    }
    if (saved_in >= 0) {
        (void)dup2(saved_in, 0);
    }
    if (saved_out >= 0) {
        (void)dup2(saved_out, 1);
    }
    if (saved_in > 2) {
        (void)close(saved_in);
    }
    if (saved_out > 2 && saved_out != saved_in) {
        (void)close(saved_out);
    }
    if (in_fd > 2 && in_fd != saved_in && in_fd != saved_out) {
        (void)close(in_fd);
    }
    if (out_fd > 2 && out_fd != saved_out && out_fd != saved_in && out_fd != in_fd) {
        (void)close(out_fd);
    }

    dbxAgentRun();
}
