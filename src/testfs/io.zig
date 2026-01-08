const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;

const handle_mod = @import("handle.zig");
const Handle = handle_mod.Handle;
const descriptors = @import("descriptors.zig");
const Descriptor = descriptors.Descriptor;
const VirtualFile = descriptors.VirtualFile;
const VirtualDir = descriptors.VirtualDir;

const TestFs = @import("root.zig").TestFs;

fn getTestFs(userdata: ?*anyopaque) *TestFs {
    return @ptrCast(@alignCast(userdata.?));
}

fn getDir(fs: *TestFs, dir_handle: Handle) ?*VirtualDir {
    if (dir_handle == handle_mod.ROOT_DIR) {
        return fs.root;
    }
    if (handle_mod.isCwd(dir_handle)) {
        return fs.cwd;
    }
    const entry = fs.handles.get(dir_handle) orelse return null;
    return switch (entry) {
        .directory => |d| d,
        .file => null,
    };
}

fn getFile(fs: *TestFs, file_handle: Handle) ?*VirtualFile {
    const entry = fs.handles.get(file_handle) orelse return null;
    return switch (entry) {
        .file => |f| f,
        .directory => null,
    };
}

pub fn dirOpenDir(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    _: Dir.OpenOptions,
) Dir.OpenError!Dir {
    const fs = getTestFs(userdata);
    const parent = getDir(fs, dir.handle) orelse return error.FileNotFound;

    const entry = descriptors.resolvePath(fs.root, parent, sub_path) orelse return error.FileNotFound;
    switch (entry) {
        .directory => |d| return .{ .handle = d.handle },
        .file => return error.NotDir,
    }
}

pub fn dirCreateDir(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    _: Dir.Permissions,
) Dir.CreateDirError!void {
    const fs = getTestFs(userdata);
    const parent = getDir(fs, dir.handle) orelse return error.FileNotFound;

    const resolved = descriptors.resolveParentAndName(fs.root, parent, sub_path) orelse return error.FileNotFound;

    if (resolved.parent == fs.root) {
        return error.ReadOnlyFileSystem;
    }

    if (resolved.parent.getEntry(resolved.name) != null) {
        return error.PathAlreadyExists;
    }

    const new_handle = fs.handle_allocator.alloc();
    const new_dir = VirtualDir.create(fs.allocator, resolved.name, new_handle, resolved.parent) catch return error.SystemResources;
    fs.handles.put(new_handle, .{ .directory = new_dir }) catch {
        new_dir.destroy(fs.allocator);
        return error.SystemResources;
    };
    resolved.parent.addEntry(.{ .directory = new_dir }) catch {
        _ = fs.handles.remove(new_handle);
        new_dir.destroy(fs.allocator);
        return error.SystemResources;
    };
}

pub fn dirCreateDirPath(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    _: Dir.Permissions,
) Dir.CreateDirPathError!Dir.CreatePathStatus {
    const fs = getTestFs(userdata);

    // For absolute paths, start from root; otherwise use the dir handle
    const is_absolute = sub_path.len > 0 and sub_path[0] == '/';
    var current = if (is_absolute) fs.root else (getDir(fs, dir.handle) orelse return error.FileNotFound);

    var path_iter = std.mem.splitScalar(u8, sub_path, '/');
    while (path_iter.next()) |component| {
        if (component.len == 0) continue;

        if (current.getEntry(component)) |existing| {
            switch (existing) {
                .directory => |d| current = d,
                .file => return error.NotDir,
            }
        } else {
            if (current == fs.root) {
                return error.ReadOnlyFileSystem;
            }

            const new_handle = fs.handle_allocator.alloc();
            const new_dir = VirtualDir.create(fs.allocator, component, new_handle, current) catch return error.SystemResources;
            fs.handles.put(new_handle, .{ .directory = new_dir }) catch {
                new_dir.destroy(fs.allocator);
                return error.SystemResources;
            };
            current.addEntry(.{ .directory = new_dir }) catch {
                _ = fs.handles.remove(new_handle);
                new_dir.destroy(fs.allocator);
                return error.SystemResources;
            };
            current = new_dir;
        }
    }

    return .created;
}

pub fn dirCreateDirPathOpen(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    perms: Dir.Permissions,
    _: Dir.OpenOptions,
) Dir.CreateDirPathOpenError!Dir {
    _ = try dirCreateDirPath(userdata, dir, sub_path, perms);
    const fs = getTestFs(userdata);
    const parent = getDir(fs, dir.handle) orelse return error.FileNotFound;
    const entry = descriptors.resolvePath(fs.root, parent, sub_path) orelse return error.FileNotFound;
    return switch (entry) {
        .directory => |d| .{ .handle = d.handle },
        .file => error.NotDir,
    };
}

pub fn dirOpenFile(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    _: File.OpenFlags,
) File.OpenError!File {
    const fs = getTestFs(userdata);
    const parent = getDir(fs, dir.handle) orelse return error.FileNotFound;

    const entry = descriptors.resolvePath(fs.root, parent, sub_path) orelse return error.FileNotFound;
    switch (entry) {
        .file => |f| {
            f.resetReadPos();
            return .{ .handle = f.handle };
        },
        .directory => return error.IsDir,
    }
}

pub fn dirCreateFile(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    _: File.CreateFlags,
) File.OpenError!File {
    const fs = getTestFs(userdata);
    const parent = getDir(fs, dir.handle) orelse return error.FileNotFound;

    const resolved = descriptors.resolveParentAndName(fs.root, parent, sub_path) orelse return error.FileNotFound;

    if (resolved.parent == fs.root) {
        return error.AccessDenied;
    }

    if (resolved.parent.getEntry(resolved.name)) |existing| {
        switch (existing) {
            .file => |f| {
                f.truncate(0);
                return .{ .handle = f.handle };
            },
            .directory => return error.IsDir,
        }
    }

    const new_handle = fs.handle_allocator.alloc();
    const new_file = VirtualFile.create(fs.allocator, resolved.name, new_handle, resolved.parent) catch return error.SystemResources;
    fs.handles.put(new_handle, .{ .file = new_file }) catch {
        new_file.destroy(fs.allocator);
        return error.SystemResources;
    };
    resolved.parent.addEntry(.{ .file = new_file }) catch {
        _ = fs.handles.remove(new_handle);
        new_file.destroy(fs.allocator);
        return error.SystemResources;
    };

    return .{ .handle = new_handle };
}

pub fn dirClose(_: ?*anyopaque, _: []const Dir) void {}

pub fn dirRead(
    userdata: ?*anyopaque,
    reader: *Dir.Reader,
    entries: []Dir.Entry,
) Dir.Reader.Error!usize {
    const fs = getTestFs(userdata);
    const dir = getDir(fs, reader.dir.handle) orelse return 0;

    dir.prepareIteration(fs.allocator) catch return 0;

    var count: usize = 0;
    while (count < entries.len) {
        const entry = dir.nextEntry() orelse {
            reader.state = .finished;
            break;
        };
        entries[count] = .{
            .name = entry.name(),
            .kind = switch (entry) {
                .file => .file,
                .directory => .directory,
            },
            .inode = 0,
        };
        count += 1;
    }

    return count;
}

pub fn dirAccess(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    _: Dir.AccessOptions,
) Dir.AccessError!void {
    const fs = getTestFs(userdata);
    const parent = getDir(fs, dir.handle) orelse return error.FileNotFound;

    _ = descriptors.resolvePath(fs.root, parent, sub_path) orelse return error.FileNotFound;
}

pub fn dirRename(
    userdata: ?*anyopaque,
    old_dir: Dir,
    old_sub_path: []const u8,
    new_dir: Dir,
    new_sub_path: []const u8,
) Dir.RenameError!void {
    const fs = getTestFs(userdata);
    const old_parent = getDir(fs, old_dir.handle) orelse return error.FileNotFound;
    const new_parent_dir = getDir(fs, new_dir.handle) orelse return error.FileNotFound;

    const old_resolved = descriptors.resolveParentAndName(fs.root, old_parent, old_sub_path) orelse return error.FileNotFound;
    const new_resolved = descriptors.resolveParentAndName(fs.root, new_parent_dir, new_sub_path) orelse return error.FileNotFound;

    const entry = old_resolved.parent.getEntry(old_resolved.name) orelse return error.FileNotFound;

    _ = old_resolved.parent.removeEntry(old_resolved.name);

    switch (entry) {
        .file => |f| {
            fs.allocator.free(f.name);
            f.name = fs.allocator.dupe(u8, new_resolved.name) catch {
                old_resolved.parent.addEntry(entry) catch {};
                return error.SystemResources;
            };
            f.parent = new_resolved.parent;
        },
        .directory => |d| {
            fs.allocator.free(d.name);
            d.name = fs.allocator.dupe(u8, new_resolved.name) catch {
                old_resolved.parent.addEntry(entry) catch {};
                return error.SystemResources;
            };
            d.parent = new_resolved.parent;
        },
    }

    new_resolved.parent.addEntry(entry) catch {
        old_resolved.parent.addEntry(entry) catch {};
        return error.SystemResources;
    };
}

pub fn fileClose(_: ?*anyopaque, _: []const File) void {}

pub fn fileSetLength(
    userdata: ?*anyopaque,
    file: File,
    length: u64,
) File.SetLengthError!void {
    const fs = getTestFs(userdata);
    const vfile = getFile(fs, file.handle) orelse return error.InputOutput;
    vfile.truncate(length);
}

pub fn fileSync(_: ?*anyopaque, _: File) File.SyncError!void {}

pub fn fileReadStreaming(
    userdata: ?*anyopaque,
    file: File,
    data: []const []u8,
) File.Reader.Error!usize {
    const fs = getTestFs(userdata);

    if (handle_mod.isStdin(file.handle)) {
        var total_read: usize = 0;
        for (data) |buffer| {
            const available = fs.stdin_data.len - fs.stdin_pos;
            if (available == 0) break;
            const to_read = @min(buffer.len, available);
            @memcpy(buffer[0..to_read], fs.stdin_data[fs.stdin_pos..][0..to_read]);
            fs.stdin_pos += to_read;
            total_read += to_read;
        }
        return total_read;
    }

    const vfile = getFile(fs, file.handle) orelse return error.NotOpenForReading;
    var total_read: usize = 0;
    for (data) |buffer| {
        const bytes_read = vfile.read(buffer);
        total_read += bytes_read;
        if (bytes_read < buffer.len) break;
    }
    return total_read;
}

pub fn fileWriteStreaming(
    userdata: ?*anyopaque,
    file: File,
    header: []const u8,
    data: []const []const u8,
    splat: usize,
) File.Writer.Error!usize {
    const fs = getTestFs(userdata);
    var total_written: usize = 0;

    if (handle_mod.isStdout(file.handle)) {
        if (header.len > 0) {
            fs.stdout_buffer.appendSlice(fs.allocator, header) catch return error.SystemResources;
            total_written += header.len;
        }
        for (data) |chunk| {
            fs.stdout_buffer.appendSlice(fs.allocator, chunk) catch return error.SystemResources;
            total_written += chunk.len;
        }
        if (splat > 0 and data.len > 0) {
            const last = data[data.len - 1];
            for (0..splat) |_| {
                fs.stdout_buffer.appendSlice(fs.allocator, last) catch return error.SystemResources;
                total_written += last.len;
            }
        }
        return total_written;
    }

    if (handle_mod.isStderr(file.handle)) {
        if (header.len > 0) {
            fs.stderr_buffer.appendSlice(fs.allocator, header) catch return error.SystemResources;
            total_written += header.len;
        }
        for (data) |chunk| {
            fs.stderr_buffer.appendSlice(fs.allocator, chunk) catch return error.SystemResources;
            total_written += chunk.len;
        }
        if (splat > 0 and data.len > 0) {
            const last = data[data.len - 1];
            for (0..splat) |_| {
                fs.stderr_buffer.appendSlice(fs.allocator, last) catch return error.SystemResources;
                total_written += last.len;
            }
        }
        return total_written;
    }

    const vfile = getFile(fs, file.handle) orelse return error.NotOpenForWriting;

    if (header.len > 0) {
        vfile.write(header) catch return error.SystemResources;
        total_written += header.len;
    }
    for (data) |chunk| {
        vfile.write(chunk) catch return error.SystemResources;
        total_written += chunk.len;
    }
    if (splat > 0 and data.len > 0) {
        const last = data[data.len - 1];
        for (0..splat) |_| {
            vfile.write(last) catch return error.SystemResources;
            total_written += last.len;
        }
    }

    return total_written;
}

fn notImplemented() noreturn {
    @panic("TestFs: function not implemented");
}

pub fn asyncFn(_: ?*anyopaque, _: []u8, _: std.mem.Alignment, _: []const u8, _: std.mem.Alignment, _: *const fn (*const anyopaque, *anyopaque) void) ?*Io.AnyFuture {
    notImplemented();
}

pub fn concurrent(_: ?*anyopaque, _: usize, _: std.mem.Alignment, _: []const u8, _: std.mem.Alignment, _: *const fn (*const anyopaque, *anyopaque) void) Io.ConcurrentError!*Io.AnyFuture {
    notImplemented();
}

pub fn await(_: ?*anyopaque, _: *Io.AnyFuture, _: []u8, _: std.mem.Alignment) void {
    notImplemented();
}

pub fn cancel(_: ?*anyopaque, _: *Io.AnyFuture, _: []u8, _: std.mem.Alignment) void {
    notImplemented();
}

pub fn groupAsync(_: ?*anyopaque, _: *Io.Group, _: []const u8, _: std.mem.Alignment, _: *const fn (*const anyopaque) Io.Cancelable!void) void {
    notImplemented();
}

pub fn groupConcurrent(_: ?*anyopaque, _: *Io.Group, _: []const u8, _: std.mem.Alignment, _: *const fn (*const anyopaque) Io.Cancelable!void) Io.ConcurrentError!void {
    notImplemented();
}

pub fn groupAwait(_: ?*anyopaque, _: *Io.Group, _: *anyopaque) Io.Cancelable!void {
    notImplemented();
}

pub fn groupCancel(_: ?*anyopaque, _: *Io.Group, _: *anyopaque) void {
    notImplemented();
}

pub fn recancel(_: ?*anyopaque) void {
    notImplemented();
}

pub fn swapCancelProtection(_: ?*anyopaque, _: Io.CancelProtection) Io.CancelProtection {
    notImplemented();
}

pub fn checkCancel(_: ?*anyopaque) Io.Cancelable!void {}

pub fn selectFn(_: ?*anyopaque, _: []const *Io.AnyFuture) Io.Cancelable!usize {
    notImplemented();
}

pub fn futexWait(_: ?*anyopaque, _: *const u32, _: u32, _: Io.Timeout) Io.Cancelable!void {
    notImplemented();
}

pub fn futexWaitUncancelable(_: ?*anyopaque, _: *const u32, _: u32) void {
    notImplemented();
}

pub fn futexWake(_: ?*anyopaque, _: *const u32, _: u32) void {
    notImplemented();
}

pub fn dirStat(_: ?*anyopaque, _: Dir) Dir.StatError!Dir.Stat {
    notImplemented();
}

pub fn dirStatFile(_: ?*anyopaque, _: Dir, _: []const u8, _: Dir.StatFileOptions) Dir.StatFileError!File.Stat {
    notImplemented();
}

pub fn dirRealPath(_: ?*anyopaque, _: Dir, _: []u8) Dir.RealPathError!usize {
    notImplemented();
}

pub fn dirRealPathFile(_: ?*anyopaque, _: Dir, _: []const u8, _: []u8) Dir.RealPathFileError!usize {
    notImplemented();
}

pub fn dirDeleteFile(_: ?*anyopaque, _: Dir, _: []const u8) Dir.DeleteFileError!void {
    notImplemented();
}

pub fn dirDeleteDir(_: ?*anyopaque, _: Dir, _: []const u8) Dir.DeleteDirError!void {
    notImplemented();
}

pub fn dirSymLink(_: ?*anyopaque, _: Dir, _: []const u8, _: []const u8, _: Dir.SymLinkFlags) Dir.SymLinkError!void {
    notImplemented();
}

pub fn dirReadLink(_: ?*anyopaque, _: Dir, _: []const u8, _: []u8) Dir.ReadLinkError!usize {
    notImplemented();
}

pub fn dirSetOwner(_: ?*anyopaque, _: Dir, _: ?File.Uid, _: ?File.Gid) Dir.SetOwnerError!void {
    notImplemented();
}

pub fn dirSetFileOwner(_: ?*anyopaque, _: Dir, _: []const u8, _: ?File.Uid, _: ?File.Gid, _: Dir.SetFileOwnerOptions) Dir.SetFileOwnerError!void {
    notImplemented();
}

pub fn dirSetPermissions(_: ?*anyopaque, _: Dir, _: Dir.Permissions) Dir.SetPermissionsError!void {
    notImplemented();
}

pub fn dirSetFilePermissions(_: ?*anyopaque, _: Dir, _: []const u8, _: File.Permissions, _: Dir.SetFilePermissionsOptions) Dir.SetFilePermissionsError!void {
    notImplemented();
}

pub fn dirSetTimestamps(_: ?*anyopaque, _: Dir, _: []const u8, _: Dir.SetTimestampsOptions) Dir.SetTimestampsError!void {
    notImplemented();
}

pub fn dirHardLink(_: ?*anyopaque, _: Dir, _: []const u8, _: Dir, _: []const u8, _: Dir.HardLinkOptions) Dir.HardLinkError!void {
    notImplemented();
}

pub fn fileStat(_: ?*anyopaque, _: File) File.StatError!File.Stat {
    notImplemented();
}

pub fn fileLength(userdata: ?*anyopaque, file: File) File.LengthError!u64 {
    const fs = getTestFs(userdata);
    const vfile = getFile(fs, file.handle) orelse return error.SystemResources;
    return vfile.content.items.len;
}

pub fn fileWritePositional(
    userdata: ?*anyopaque,
    file: File,
    header: []const u8,
    data: []const []const u8,
    splat: usize,
    _: u64,
) File.WritePositionalError!usize {
    return fileWriteStreaming(userdata, file, header, data, splat) catch |err| switch (err) {
        error.SystemResources => return error.SystemResources,
        error.Canceled => return error.Canceled,
        error.Unexpected => return error.Unexpected,
        else => return error.Unexpected,
    };
}

pub fn fileWriteFileStreaming(_: ?*anyopaque, _: File, _: []const u8, _: *Io.File.Reader, _: Io.Limit) File.Writer.WriteFileError!usize {
    notImplemented();
}

pub fn fileWriteFilePositional(_: ?*anyopaque, _: File, _: []const u8, _: *Io.File.Reader, _: Io.Limit, _: u64) File.WriteFilePositionalError!usize {
    notImplemented();
}

pub fn fileReadPositional(
    userdata: ?*anyopaque,
    file: File,
    data: []const []u8,
    offset: u64,
) File.ReadPositionalError!usize {
    const fs = getTestFs(userdata);

    if (handle_mod.isStdin(file.handle)) {
        var total_read: usize = 0;
        var pos = @as(usize, @intCast(offset));
        for (data) |buffer| {
            if (pos >= fs.stdin_data.len) break;
            const available = fs.stdin_data.len - pos;
            const to_read = @min(buffer.len, available);
            @memcpy(buffer[0..to_read], fs.stdin_data[pos..][0..to_read]);
            pos += to_read;
            total_read += to_read;
        }
        return total_read;
    }

    const vfile = getFile(fs, file.handle) orelse return error.NotOpenForReading;
    var total_read: usize = 0;
    var pos = @as(usize, @intCast(offset));
    for (data) |buffer| {
        if (pos >= vfile.content.items.len) break;
        const available = vfile.content.items.len - pos;
        const to_read = @min(buffer.len, available);
        @memcpy(buffer[0..to_read], vfile.content.items[pos..][0..to_read]);
        pos += to_read;
        total_read += to_read;
    }
    return total_read;
}

pub fn fileSeekBy(_: ?*anyopaque, _: File, _: i64) File.SeekError!void {
    notImplemented();
}

pub fn fileSeekTo(_: ?*anyopaque, _: File, _: u64) File.SeekError!void {
    notImplemented();
}

pub fn fileIsTty(_: ?*anyopaque, _: File) Io.Cancelable!bool {
    return false;
}

pub fn fileEnableAnsiEscapeCodes(_: ?*anyopaque, _: File) File.EnableAnsiEscapeCodesError!void {}

pub fn fileSupportsAnsiEscapeCodes(_: ?*anyopaque, _: File) Io.Cancelable!bool {
    return false;
}

pub fn fileSetOwner(_: ?*anyopaque, _: File, _: ?File.Uid, _: ?File.Gid) File.SetOwnerError!void {
    notImplemented();
}

pub fn fileSetPermissions(_: ?*anyopaque, _: File, _: File.Permissions) File.SetPermissionsError!void {
    notImplemented();
}

pub fn fileSetTimestamps(_: ?*anyopaque, _: File, _: File.SetTimestampsOptions) File.SetTimestampsError!void {
    notImplemented();
}

pub fn fileLock(_: ?*anyopaque, _: File, _: File.Lock) File.LockError!void {
    notImplemented();
}

pub fn fileTryLock(_: ?*anyopaque, _: File, _: File.Lock) File.LockError!bool {
    notImplemented();
}

pub fn fileUnlock(_: ?*anyopaque, _: File) void {
    notImplemented();
}

pub fn fileDowngradeLock(_: ?*anyopaque, _: File) File.DowngradeLockError!void {
    notImplemented();
}

pub fn fileRealPath(_: ?*anyopaque, _: File, _: []u8) File.RealPathError!usize {
    notImplemented();
}

pub fn processExecutableOpen(_: ?*anyopaque, _: File.OpenFlags) std.process.OpenExecutableError!File {
    notImplemented();
}

pub fn processExecutablePath(_: ?*anyopaque, _: []u8) std.process.ExecutablePathError!usize {
    notImplemented();
}

pub fn lockStderr(_: ?*anyopaque, _: ?Io.Terminal.Mode) Io.Cancelable!Io.LockedStderr {
    notImplemented();
}

pub fn tryLockStderr(_: ?*anyopaque, _: ?Io.Terminal.Mode) Io.Cancelable!?Io.LockedStderr {
    notImplemented();
}

pub fn unlockStderr(_: ?*anyopaque) void {
    notImplemented();
}

pub fn processSetCurrentDir(_: ?*anyopaque, _: Dir) std.process.SetCurrentDirError!void {
    notImplemented();
}

pub fn now(_: ?*anyopaque, _: Io.Clock) Io.Clock.Error!Io.Timestamp {
    return Io.Timestamp.zero;
}

pub fn sleep(_: ?*anyopaque, _: Io.Timeout) Io.SleepError!void {}

pub fn netListenIp(_: ?*anyopaque, _: Io.net.IpAddress, _: Io.net.IpAddress.ListenOptions) Io.net.IpAddress.ListenError!Io.net.Server {
    notImplemented();
}

pub fn netAccept(_: ?*anyopaque, _: Io.net.Socket.Handle) Io.net.Server.AcceptError!Io.net.Stream {
    notImplemented();
}

pub fn netBindIp(_: ?*anyopaque, _: *const Io.net.IpAddress, _: Io.net.IpAddress.BindOptions) Io.net.IpAddress.BindError!Io.net.Socket {
    notImplemented();
}

pub fn netConnectIp(_: ?*anyopaque, _: *const Io.net.IpAddress, _: Io.net.IpAddress.ConnectOptions) Io.net.IpAddress.ConnectError!Io.net.Stream {
    notImplemented();
}

pub fn netListenUnix(_: ?*anyopaque, _: *const Io.net.UnixAddress, _: Io.net.UnixAddress.ListenOptions) Io.net.UnixAddress.ListenError!Io.net.Socket.Handle {
    notImplemented();
}

pub fn netConnectUnix(_: ?*anyopaque, _: *const Io.net.UnixAddress) Io.net.UnixAddress.ConnectError!Io.net.Socket.Handle {
    notImplemented();
}

pub fn netSend(_: ?*anyopaque, _: Io.net.Socket.Handle, _: []Io.net.OutgoingMessage, _: Io.net.SendFlags) struct { ?Io.net.Socket.SendError, usize } {
    notImplemented();
}

pub fn netReceive(_: ?*anyopaque, _: Io.net.Socket.Handle, _: []Io.net.IncomingMessage, _: []u8, _: Io.net.ReceiveFlags, _: Io.Timeout) struct { ?Io.net.Socket.ReceiveTimeoutError, usize } {
    notImplemented();
}

pub fn netRead(_: ?*anyopaque, _: Io.net.Socket.Handle, _: [][]u8) Io.net.Stream.Reader.Error!usize {
    notImplemented();
}

pub fn netWrite(_: ?*anyopaque, _: Io.net.Socket.Handle, _: []const u8, _: []const []const u8, _: usize) Io.net.Stream.Writer.Error!usize {
    notImplemented();
}

pub fn netWriteFile(_: ?*anyopaque, _: Io.net.Socket.Handle, _: []const u8, _: *Io.File.Reader, _: Io.Limit) Io.net.Stream.Writer.WriteFileError!usize {
    notImplemented();
}

pub fn netClose(_: ?*anyopaque, _: []const Io.net.Socket.Handle) void {
    notImplemented();
}

pub fn netShutdown(_: ?*anyopaque, _: Io.net.Socket.Handle, _: Io.net.ShutdownHow) Io.net.ShutdownError!void {
    notImplemented();
}

pub fn netInterfaceNameResolve(_: ?*anyopaque, _: *const Io.net.Interface.Name) Io.net.Interface.Name.ResolveError!Io.net.Interface {
    notImplemented();
}

pub fn netInterfaceName(_: ?*anyopaque, _: Io.net.Interface) Io.net.Interface.NameError!Io.net.Interface.Name {
    notImplemented();
}

pub fn netLookup(_: ?*anyopaque, _: Io.net.HostName, _: *Io.Queue(Io.net.HostName.LookupResult), _: Io.net.HostName.LookupOptions) Io.net.HostName.LookupError!void {
    notImplemented();
}

pub const vtable = Io.VTable{
    .async = asyncFn,
    .concurrent = concurrent,
    .await = await,
    .cancel = cancel,
    .groupAsync = groupAsync,
    .groupConcurrent = groupConcurrent,
    .groupAwait = groupAwait,
    .groupCancel = groupCancel,
    .recancel = recancel,
    .swapCancelProtection = swapCancelProtection,
    .checkCancel = checkCancel,
    .select = selectFn,
    .futexWait = futexWait,
    .futexWaitUncancelable = futexWaitUncancelable,
    .futexWake = futexWake,
    .dirCreateDir = dirCreateDir,
    .dirCreateDirPath = dirCreateDirPath,
    .dirCreateDirPathOpen = dirCreateDirPathOpen,
    .dirOpenDir = dirOpenDir,
    .dirStat = dirStat,
    .dirStatFile = dirStatFile,
    .dirAccess = dirAccess,
    .dirCreateFile = dirCreateFile,
    .dirOpenFile = dirOpenFile,
    .dirClose = dirClose,
    .dirRead = dirRead,
    .dirRealPath = dirRealPath,
    .dirRealPathFile = dirRealPathFile,
    .dirDeleteFile = dirDeleteFile,
    .dirDeleteDir = dirDeleteDir,
    .dirRename = dirRename,
    .dirSymLink = dirSymLink,
    .dirReadLink = dirReadLink,
    .dirSetOwner = dirSetOwner,
    .dirSetFileOwner = dirSetFileOwner,
    .dirSetPermissions = dirSetPermissions,
    .dirSetFilePermissions = dirSetFilePermissions,
    .dirSetTimestamps = dirSetTimestamps,
    .dirHardLink = dirHardLink,
    .fileStat = fileStat,
    .fileLength = fileLength,
    .fileClose = fileClose,
    .fileWriteStreaming = fileWriteStreaming,
    .fileWritePositional = fileWritePositional,
    .fileWriteFileStreaming = fileWriteFileStreaming,
    .fileWriteFilePositional = fileWriteFilePositional,
    .fileReadStreaming = fileReadStreaming,
    .fileReadPositional = fileReadPositional,
    .fileSeekBy = fileSeekBy,
    .fileSeekTo = fileSeekTo,
    .fileSync = fileSync,
    .fileIsTty = fileIsTty,
    .fileEnableAnsiEscapeCodes = fileEnableAnsiEscapeCodes,
    .fileSupportsAnsiEscapeCodes = fileSupportsAnsiEscapeCodes,
    .fileSetLength = fileSetLength,
    .fileSetOwner = fileSetOwner,
    .fileSetPermissions = fileSetPermissions,
    .fileSetTimestamps = fileSetTimestamps,
    .fileLock = fileLock,
    .fileTryLock = fileTryLock,
    .fileUnlock = fileUnlock,
    .fileDowngradeLock = fileDowngradeLock,
    .fileRealPath = fileRealPath,
    .processExecutableOpen = processExecutableOpen,
    .processExecutablePath = processExecutablePath,
    .lockStderr = lockStderr,
    .tryLockStderr = tryLockStderr,
    .unlockStderr = unlockStderr,
    .processSetCurrentDir = processSetCurrentDir,
    .now = now,
    .sleep = sleep,
    .netListenIp = netListenIp,
    .netAccept = netAccept,
    .netBindIp = netBindIp,
    .netConnectIp = netConnectIp,
    .netListenUnix = netListenUnix,
    .netConnectUnix = netConnectUnix,
    .netSend = netSend,
    .netReceive = netReceive,
    .netRead = netRead,
    .netWrite = netWrite,
    .netWriteFile = netWriteFile,
    .netClose = netClose,
    .netShutdown = netShutdown,
    .netInterfaceNameResolve = netInterfaceNameResolve,
    .netInterfaceName = netInterfaceName,
    .netLookup = netLookup,
};
