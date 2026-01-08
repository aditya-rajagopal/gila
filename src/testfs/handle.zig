const std = @import("std");
const builtin = @import("builtin");

pub const Handle = std.posix.fd_t;

pub const STDIN: Handle = 0;
pub const STDOUT: Handle = 1;
pub const STDERR: Handle = 2;

pub const CWD: Handle = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos => -2,
    .windows => @compileError("Windows CWD handle not supported in testfs"),
    else => -100,
};

pub const ROOT_DIR: Handle = 100;

pub const FIRST_DYNAMIC: Handle = 1000;

pub fn isStdio(handle: Handle) bool {
    return handle == STDIN or handle == STDOUT or handle == STDERR;
}

pub fn isStdin(handle: Handle) bool {
    return handle == STDIN;
}

pub fn isStdout(handle: Handle) bool {
    return handle == STDOUT;
}

pub fn isStderr(handle: Handle) bool {
    return handle == STDERR;
}

pub fn isCwd(handle: Handle) bool {
    return handle == CWD;
}

pub const HandleAllocator = struct {
    next: Handle = FIRST_DYNAMIC,

    pub fn alloc(self: *HandleAllocator) Handle {
        const handle = self.next;
        self.next += 1;
        return handle;
    }

    pub fn reset(self: *HandleAllocator) void {
        self.next = FIRST_DYNAMIC;
    }
};
