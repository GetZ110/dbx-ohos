//! OHOS native child process（NCP）入口，Rust 侧与 Go 侧 shim 等价。
//!
//! 子进程由 appspawn 以应用身份创建：系统 `dlopen` 本库（不走 `execve`，因此
//! 不需要执行位、也不需要代码签名身份），然后在一个线程上调用导出的
//! `Main(NativeChildProcess_Args)`，`Main` 返回后子进程退出。
//!
//! 父进程（`crates/dbx-core/src/db/agent_ncp.rs`）用 `socketpair` 建通道，把一端
//! 通过 `fdList` 传进来；这里把那（些）fd `dup2` 到 0/1，于是原有的
//! stdin/stdout JSON-RPC 循环可以原样复用（只是管道换成了 socketpair）。
//!
//! 行为与 `agents/drivers/oracle-go/ohos_ncp_shim.c` 保持一致（含 `in`/`stdin`、
//! `out`/`stdout` 命名约定、单 fd 同时当读写、先把 fd 挪到 >=3 再 dup2）。
//!
//! 本文件对所有 Rust agent 完全相同；驱动侧的收尾逻辑放在各自 `lib.rs` 的
//! `run_stdio_agent()` 里。

use std::os::raw::{c_char, c_int};

#[repr(C)]
pub struct NativeChildProcessFd {
    fd_name: *mut c_char,
    fd: i32,
    next: *mut NativeChildProcessFd,
}

#[repr(C)]
pub struct NativeChildProcessFdList {
    head: *mut NativeChildProcessFd,
}

#[repr(C)]
pub struct NativeChildProcessArgs {
    entry_params: *mut c_char,
    fd_list: NativeChildProcessFdList,
}

/// `fcntl(2)` 的 F_DUPFD（Linux/OHOS 上恒为 0）。
const F_DUPFD: c_int = 0;

unsafe extern "C" {
    fn dup2(oldfd: c_int, newfd: c_int) -> c_int;
    fn fcntl(fd: c_int, cmd: c_int, ...) -> c_int;
    fn close(fd: c_int) -> c_int;
}

/// 挪到 >= 3 的 fd 上，避免后面 dup2 时互相覆盖。
fn move_above_std(fd: c_int) -> c_int {
    if fd > 2 {
        return fd;
    }
    unsafe { fcntl(fd, F_DUPFD, 3 as c_int) }
}

fn name_is(ptr: *const c_char, a: &[u8], b: &[u8]) -> bool {
    if ptr.is_null() {
        return false;
    }
    let name = unsafe { std::ffi::CStr::from_ptr(ptr) }.to_bytes();
    name == a || name == b
}

/// 系统固定入口：`dlopen(<lib>.so)` 后调用 `Main(args)`，返回即子进程退出。
#[no_mangle]
pub extern "C" fn Main(args: NativeChildProcessArgs) {
    let mut in_fd: c_int = -1;
    let mut out_fd: c_int = -1;
    let mut index = 0;
    let mut node = args.fd_list.head;

    while !node.is_null() {
        let entry = unsafe { &*node };
        if name_is(entry.fd_name, b"in", b"stdin") {
            in_fd = entry.fd;
        } else if name_is(entry.fd_name, b"out", b"stdout") {
            out_fd = entry.fd;
        } else if index == 0 && in_fd < 0 {
            in_fd = entry.fd;
        } else if index == 1 && out_fd < 0 {
            out_fd = entry.fd;
        }
        node = entry.next;
        index += 1;
    }
    if in_fd < 0 {
        in_fd = out_fd;
    }
    if out_fd < 0 {
        out_fd = in_fd;
    }

    let saved_in = if in_fd >= 0 { move_above_std(in_fd) } else { -1 };
    let saved_out = if out_fd >= 0 { move_above_std(out_fd) } else { -1 };

    unsafe {
        if saved_in >= 0 {
            let _ = dup2(saved_in, 0);
        }
        if saved_out >= 0 {
            let _ = dup2(saved_out, 1);
        }
        if saved_in > 2 {
            let _ = close(saved_in);
        }
        if saved_out > 2 && saved_out != saved_in {
            let _ = close(saved_out);
        }
        if in_fd > 2 && in_fd != saved_in && in_fd != saved_out {
            let _ = close(in_fd);
        }
        if out_fd > 2 && out_fd != saved_out && out_fd != saved_in && out_fd != in_fd {
            let _ = close(out_fd);
        }
    }

    crate::run_stdio_agent();
}
