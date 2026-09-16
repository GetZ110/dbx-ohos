/*
 * 对照组小库：用来回答"沙箱里的 .so 能不能被 dlopen"。
 *
 * 它自己用 OHOS NDK 编出来、musl 兼容，放进 HAP 的 rawfile，由 ArkTS 在运行时
 * 拷进应用沙箱（filesDir），再由子进程里的 jvm_probe 去 dlopen。
 * 这样就能把两件事分开：
 *   - dlopen 被 code_protect/BinSec 拒 → 沙箱 .so 一律加载不了（硬阻塞）；
 *   - dlopen 成功 → 沙箱 .so 可以加载，JRE 卡的是别的（libc 不匹配）。
 */
int ncp_sandbox_marker(void)
{
    return 42;
}
