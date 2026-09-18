//go:build ohos_ncp

// OHOS native child process 版本的入口（仅在 -tags ohos_ncp 时参与编译）。
//
// 子进程由 appspawn 以应用身份创建，入口 `Main` 由 ohos_ncp_shim.c 提供：
// 它把 parent 通过 fdList 传进来的 fd dup2 到 0/1，然后调用这里的 dbxAgentRun，
// 于是原有的 stdin/stdout JSON-RPC 循环可以原样复用（只是管道换成了 socketpair）。
package main

/*
#include <stdbool.h>
#include <AbilityKit/native_child_process.h>
#include <unistd.h>

// 由本文件导出，供 shim 调用。
void dbxAgentRun(void);
*/
import "C"

//export dbxAgentRun
func dbxAgentRun() {
	runStdioAgent()
}
