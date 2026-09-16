/*
 * Native child process spike：验证 HarmonyOS 允许应用从 HAP 的 libs/ 里
 * 以 dlopen 方式启动子进程（不需要 exec，因此不需要文件的 x 位/签名）。
 *
 * 入口签名固定为 `void Main(NativeChildProcess_Args args)`，
 * 由主进程用 childProcessManager.startNativeChildProcess("libdbx_ncpspike.so:Main", ...) 指定。
 */
#include <stdbool.h>
#include <AbilityKit/native_child_process.h>
#include <hilog/log.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>

#undef LOG_DOMAIN
#define LOG_DOMAIN 0xDB3
#undef LOG_TAG
#define LOG_TAG "DBX_NCP"

void Main(NativeChildProcess_Args args)
{
    OH_LOG_INFO(LOG_APP, "NCP_CHILD start params=%{public}s",
        args.entryParams != NULL ? args.entryParams : "(null)");

    const char *hello = "{\"ready\":true,\"from\":\"child\"}\n";
    int count = 0;
    for (NativeChildProcess_Fd *fd = args.fdList.head; fd != NULL; fd = fd->next) {
        count++;
        ssize_t written = write(fd->fd, hello, strlen(hello));
        OH_LOG_INFO(LOG_APP, "NCP_CHILD fd[%{public}d] name=%{public}s fd=%{public}d written=%{public}d",
            count, fd->fdName != NULL ? fd->fdName : "(null)", fd->fd, (int)written);
    }

    /* entryParams 里带的路径写一个标记文件，证明子进程真的以应用身份跑起来了 */
    if (args.entryParams != NULL) {
        int f = open(args.entryParams, O_CREAT | O_WRONLY | O_TRUNC, 0644);
        if (f >= 0) {
            const char *marker = "child-ran\n";
            ssize_t written = write(f, marker, strlen(marker));
            OH_LOG_INFO(LOG_APP, "NCP_CHILD marker written=%{public}d path=%{public}s",
                (int)written, args.entryParams);
            close(f);
        } else {
            OH_LOG_ERROR(LOG_APP, "NCP_CHILD marker open failed, path=%{public}s",
                args.entryParams);
        }
    }
    OH_LOG_INFO(LOG_APP, "NCP_CHILD exit fdCount=%{public}d", count);
}
