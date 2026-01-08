const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;

const handle_mod = @import("handle.zig");
pub const Handle = handle_mod.Handle;
const descriptors = @import("descriptors.zig");
pub const Descriptor = descriptors.Descriptor;
pub const VirtualFile = descriptors.VirtualFile;
pub const VirtualDir = descriptors.VirtualDir;
const virtual_io = @import("io.zig");

pub const TestFs = struct {
    allocator: std.mem.Allocator,
    root: *VirtualDir,
    cwd: *VirtualDir,
    handles: std.AutoHashMap(Handle, Descriptor),
    handle_allocator: handle_mod.HandleAllocator,

    stdout_buffer: std.ArrayList(u8),
    stderr_buffer: std.ArrayList(u8),

    stdin_data: []const u8,
    stdin_pos: usize,

    pub fn setup(allocator: std.mem.Allocator) !*TestFs {
        const fs = try allocator.create(TestFs);
        errdefer allocator.destroy(fs);

        const root_dir = try VirtualDir.create(allocator, "", handle_mod.ROOT_DIR, null);
        errdefer root_dir.destroy(allocator);

        fs.* = .{
            .allocator = allocator,
            .root = root_dir,
            .cwd = root_dir,
            .handles = std.AutoHashMap(Handle, Descriptor).init(allocator),
            .handle_allocator = .{},
            .stdout_buffer = .{},
            .stderr_buffer = .{},
            .stdin_data = "",
            .stdin_pos = 0,
        };

        try fs.handles.put(handle_mod.ROOT_DIR, .{ .directory = root_dir });

        const home_dir = try fs.setupRootDir("home");
        const test_handle = fs.handle_allocator.alloc();
        const test_dir = try VirtualDir.create(allocator, "test", test_handle, home_dir);
        try fs.handles.put(test_handle, .{ .directory = test_dir });
        try home_dir.addEntry(.{ .directory = test_dir });
        fs.cwd = test_dir;

        return fs;
    }

    pub fn deinit(self: *TestFs) void {
        self.root.destroy(self.allocator);
        self.handles.deinit();
        self.stdout_buffer.deinit(self.allocator);
        self.stderr_buffer.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn io(self: *TestFs) Io {
        return .{
            .userdata = self,
            .vtable = &virtual_io.vtable,
        };
    }

    pub fn rootDir(self: *TestFs) Dir {
        _ = self;
        return .{ .handle = handle_mod.ROOT_DIR };
    }

    pub fn setCwd(self: *TestFs, path: []const u8) !void {
        if (path.len == 0) {
            const home = self.root.getEntry("home") orelse return error.NotFound;
            switch (home) {
                .directory => |d| {
                    const test_dir = d.getEntry("test") orelse return error.NotFound;
                    switch (test_dir) {
                        .directory => |td| self.cwd = td,
                        .file => return error.NotDirectory,
                    }
                },
                .file => return error.NotDirectory,
            }
            return;
        }
        const is_absolute = path[0] == '/';
        const base_dir = if (is_absolute) self.root else self.cwd;
        const entry = descriptors.resolvePath(self.root, base_dir, path) orelse return error.NotFound;
        switch (entry) {
            .directory => |d| self.cwd = d,
            .file => return error.NotDirectory,
        }
    }

    pub fn getCwdDir(self: *TestFs) *VirtualDir {
        return self.cwd;
    }

    pub fn setStdin(self: *TestFs, data: []const u8) void {
        self.stdin_data = data;
        self.stdin_pos = 0;
    }

    pub fn getStdout(self: *TestFs) []const u8 {
        return self.stdout_buffer.items;
    }

    pub fn getStderr(self: *TestFs) []const u8 {
        return self.stderr_buffer.items;
    }

    pub fn clearStdout(self: *TestFs) void {
        self.stdout_buffer.clearRetainingCapacity();
    }

    pub fn clearStderr(self: *TestFs) void {
        self.stderr_buffer.clearRetainingCapacity();
    }

    pub fn createDir(self: *TestFs, path: []const u8) !void {
        const is_absolute = path.len > 0 and path[0] == '/';
        var current = if (is_absolute) self.root else self.cwd;
        var path_iter = std.mem.splitScalar(u8, path, '/');
        while (path_iter.next()) |component| {
            if (component.len == 0) continue;

            if (current.getEntry(component)) |existing| {
                switch (existing) {
                    .directory => |d| current = d,
                    .file => return error.Failed,
                }
            } else {
                const new_handle = self.handle_allocator.alloc();
                const new_dir = VirtualDir.create(self.allocator, component, new_handle, current) catch return error.Failed;
                self.handles.put(new_handle, .{ .directory = new_dir }) catch {
                    new_dir.destroy(self.allocator);
                    return error.Failed;
                };
                current.addEntry(.{ .directory = new_dir }) catch {
                    _ = self.handles.remove(new_handle);
                    new_dir.destroy(self.allocator);
                    return error.Failed;
                };
                current = new_dir;
            }
        }
    }

    pub fn setupRootDir(self: *TestFs, name: []const u8) !*VirtualDir {
        if (self.root.getEntry(name) != null) {
            return error.Failed;
        }

        const new_handle = self.handle_allocator.alloc();
        const new_dir = VirtualDir.create(self.allocator, name, new_handle, self.root) catch return error.Failed;
        self.handles.put(new_handle, .{ .directory = new_dir }) catch {
            new_dir.destroy(self.allocator);
            return error.Failed;
        };
        self.root.addEntry(.{ .directory = new_dir }) catch {
            _ = self.handles.remove(new_handle);
            new_dir.destroy(self.allocator);
            return error.Failed;
        };
        return new_dir;
    }

    pub fn createFile(self: *TestFs, path: []const u8, content: []const u8) !void {
        const last_slash = std.mem.lastIndexOfScalar(u8, path, '/');
        if (last_slash) |idx| {
            const dir_path = path[0..idx];
            try self.createDir(dir_path);
        }

        const is_absolute = path.len > 0 and path[0] == '/';
        const base_dir = if (is_absolute) self.root else self.cwd;
        const resolved = descriptors.resolveParentAndName(self.root, base_dir, path) orelse return error.Failed;

        if (resolved.parent.getEntry(resolved.name)) |existing| {
            switch (existing) {
                .file => |f| {
                    f.truncate(0);
                    f.write(content) catch return error.Failed;
                    return;
                },
                .directory => return error.Failed,
            }
        }

        const new_handle = self.handle_allocator.alloc();
        const new_file = VirtualFile.create(self.allocator, resolved.name, new_handle, resolved.parent) catch return error.Failed;
        self.handles.put(new_handle, .{ .file = new_file }) catch {
            new_file.destroy(self.allocator);
            return error.Failed;
        };
        resolved.parent.addEntry(.{ .file = new_file }) catch {
            _ = self.handles.remove(new_handle);
            new_file.destroy(self.allocator);
            return error.Failed;
        };

        new_file.write(content) catch return error.Failed;
    }

    pub fn readFile(self: *TestFs, path: []const u8) ![]const u8 {
        const is_absolute = path.len > 0 and path[0] == '/';
        const base_dir = if (is_absolute) null else self.cwd;
        const entry = descriptors.resolvePath(self.root, base_dir, path) orelse return error.FileNotFound;
        switch (entry) {
            .file => |f| return f.content.items,
            .directory => return error.IsDirectory,
        }
    }

    pub fn fileExists(self: *TestFs, path: []const u8) bool {
        const is_absolute = path.len > 0 and path[0] == '/';
        const base_dir = if (is_absolute) null else self.cwd;
        const entry = descriptors.resolvePath(self.root, base_dir, path) orelse return false;
        return switch (entry) {
            .file => true,
            .directory => false,
        };
    }

    pub fn dirExists(self: *TestFs, path: []const u8) bool {
        const is_absolute = path.len > 0 and path[0] == '/';
        const base_dir = if (is_absolute) null else self.cwd;
        const entry = descriptors.resolvePath(self.root, base_dir, path) orelse return false;
        return switch (entry) {
            .file => false,
            .directory => true,
        };
    }

    pub fn listDir(self: *TestFs, path: []const u8) ![]const []const u8 {
        const is_absolute = path.len > 0 and path[0] == '/';
        const base_dir = if (is_absolute) null else self.cwd;
        const entry = descriptors.resolvePath(self.root, base_dir, path) orelse return error.FileNotFound;
        switch (entry) {
            .directory => |dir| {
                const count = dir.entries.count();
                const names = try self.allocator.alloc([]const u8, count);
                var i: usize = 0;
                var iter = dir.entries.keyIterator();
                while (iter.next()) |key| {
                    names[i] = key.*;
                    i += 1;
                }
                return names;
            },
            .file => return error.NotDirectory,
        }
    }
};

test "TestFs.setup and deinit" {
    const fs = try TestFs.setup(std.testing.allocator);
    defer fs.deinit();

    try std.testing.expectEqual(handle_mod.ROOT_DIR, fs.root.handle);
}

test "TestFs.createDir" {
    const fs = try TestFs.setup(std.testing.allocator);
    defer fs.deinit();

    try fs.createDir("foo");
    try std.testing.expect(fs.dirExists("foo"));

    try fs.createDir("foo/bar/baz");
    try std.testing.expect(fs.dirExists("foo/bar"));
    try std.testing.expect(fs.dirExists("foo/bar/baz"));
}

test "TestFs.createFile and readFile" {
    const fs = try TestFs.setup(std.testing.allocator);
    defer fs.deinit();

    try fs.createFile("test.txt", "Hello, World!");
    try std.testing.expect(fs.fileExists("test.txt"));

    const content = try fs.readFile("test.txt");
    try std.testing.expectEqualStrings("Hello, World!", content);
}

test "TestFs.createFile with nested path" {
    const fs = try TestFs.setup(std.testing.allocator);
    defer fs.deinit();

    try fs.createFile("a/b/c/file.txt", "nested content");
    try std.testing.expect(fs.dirExists("a"));
    try std.testing.expect(fs.dirExists("a/b"));
    try std.testing.expect(fs.dirExists("a/b/c"));
    try std.testing.expect(fs.fileExists("a/b/c/file.txt"));

    const content = try fs.readFile("a/b/c/file.txt");
    try std.testing.expectEqualStrings("nested content", content);
}

test "TestFs.stdin/stdout" {
    const fs = try TestFs.setup(std.testing.allocator);
    defer fs.deinit();

    fs.setStdin("test input data");

    var buffer: [1024]u8 = undefined;
    const stdin = File.stdin();
    var reader = stdin.reader(fs.io(), &buffer);
    const line = reader.interface.takeDelimiter(' ') catch null;

    try std.testing.expect(line != null);
    try std.testing.expectEqualStrings("test", line.?);
}

test "TestFs.stdout write" {
    const fs = try TestFs.setup(std.testing.allocator);
    defer fs.deinit();

    const stdout = File.stdout();
    var buffer: [1024]u8 = undefined;
    var writer = stdout.writer(fs.io(), &buffer);
    writer.interface.print("Hello {s}!", .{"world"}) catch unreachable;
    writer.interface.flush() catch unreachable;

    try std.testing.expectEqualStrings("Hello world!", fs.getStdout());
}

test "TestFs.file read/write via io" {
    const fs = try TestFs.setup(std.testing.allocator);
    defer fs.deinit();

    const ioface = fs.io();
    const cwd = Dir.cwd();

    const file = try cwd.createFile(ioface, "test.txt", .{});
    {
        var write_buffer: [256]u8 = undefined;
        var writer = file.writer(ioface, &write_buffer);
        try writer.interface.print("Line 1\nLine 2\n", .{});
        try writer.interface.flush();
    }

    const read_file = try cwd.openFile(ioface, "test.txt", .{ .mode = .read_only });
    {
        var read_buffer: [256]u8 = undefined;
        var reader = read_file.reader(ioface, &read_buffer);
        try reader.interface.fillMore();

        const line1 = try reader.interface.takeDelimiter('\n');
        try std.testing.expectEqualStrings("Line 1", line1.?);

        const line2 = try reader.interface.takeDelimiter('\n');
        try std.testing.expectEqualStrings("Line 2", line2.?);
    }
}

test "TestFs.directory iteration" {
    const fs = try TestFs.setup(std.testing.allocator);
    defer fs.deinit();

    try fs.createDir("mydir");
    try fs.createFile("mydir/file1.txt", "content1");
    try fs.createFile("mydir/file2.txt", "content2");
    try fs.createDir("mydir/subdir");

    const ioface = fs.io();
    const cwd = Dir.cwd();

    const dir = try cwd.openDir(ioface, "mydir", .{ .iterate = true });

    var found_file1 = false;
    var found_file2 = false;
    var found_subdir = false;

    var dir_walker = dir.iterateAssumeFirstIteration();
    while (try dir_walker.next(ioface)) |entry| {
        if (std.mem.eql(u8, entry.name, "file1.txt")) found_file1 = true;
        if (std.mem.eql(u8, entry.name, "file2.txt")) found_file2 = true;
        if (std.mem.eql(u8, entry.name, "subdir")) found_subdir = true;
    }

    try std.testing.expect(found_file1);
    try std.testing.expect(found_file2);
    try std.testing.expect(found_subdir);
}

test "TestFs.rename" {
    const fs = try TestFs.setup(std.testing.allocator);
    defer fs.deinit();

    try fs.createFile("old.txt", "content");
    try std.testing.expect(fs.fileExists("old.txt"));

    const ioface = fs.io();
    const cwd = Dir.cwd();
    try cwd.rename("old.txt", cwd, "new.txt", ioface);

    try std.testing.expect(!fs.fileExists("old.txt"));
    try std.testing.expect(fs.fileExists("new.txt"));

    const content = try fs.readFile("new.txt");
    try std.testing.expectEqualStrings("content", content);
}

test "TestFs.rename directory" {
    const fs = try TestFs.setup(std.testing.allocator);
    defer fs.deinit();

    try fs.createDir("olddir/subdir");
    try fs.createFile("olddir/file.txt", "content");
    try fs.createDir("newparent");

    const ioface = fs.io();
    const cwd = Dir.cwd();
    try cwd.rename("olddir", cwd, "newparent/newdir", ioface);

    try std.testing.expect(!fs.dirExists("olddir"));
    try std.testing.expect(fs.dirExists("newparent/newdir"));
}

test "Dir.cwd() basic usage" {
    const fs = try TestFs.setup(std.testing.allocator);
    defer fs.deinit();

    const ioface = fs.io();
    const cwd = Dir.cwd();

    try cwd.createDirPath(ioface, "testdir");
    try std.testing.expect(fs.dirExists("testdir"));

    const file = try cwd.createFile(ioface, "testdir/hello.txt", .{});
    {
        var buffer: [256]u8 = undefined;
        var writer = file.writer(ioface, &buffer);
        try writer.interface.print("Hello from cwd!", .{});
        try writer.interface.flush();
    }

    const content = try fs.readFile("testdir/hello.txt");
    try std.testing.expectEqualStrings("Hello from cwd!", content);
}

test "Dir.cwd() with setCwd" {
    const fs = try TestFs.setup(std.testing.allocator);
    defer fs.deinit();

    try fs.createDir("project/src/lib");
    try fs.createFile("project/src/lib/main.zig", "const std = @import(\"std\");");

    try fs.setCwd("project/src");

    const ioface = fs.io();
    const cwd = Dir.cwd();

    const dir = try cwd.openDir(ioface, "lib", .{});
    const file = try dir.openFile(ioface, "main.zig", .{ .mode = .read_only });
    var buffer: [256]u8 = undefined;
    var reader = file.reader(ioface, &buffer);
    try reader.interface.fillMore();
    const line = try reader.interface.takeDelimiter(';');
    try std.testing.expectEqualStrings("const std = @import(\"std\")", line.?);
}

test "path traversal with .." {
    const fs = try TestFs.setup(std.testing.allocator);
    defer fs.deinit();

    try fs.createDir("a/b/c");
    try fs.createFile("a/root.txt", "root content");
    try fs.createFile("a/b/c/deep.txt", "deep content");

    try fs.setCwd("a/b/c");

    const ioface = fs.io();
    const cwd = Dir.cwd();

    const parent_file = try cwd.openFile(ioface, "../../root.txt", .{ .mode = .read_only });
    var buffer: [256]u8 = undefined;
    var reader = parent_file.reader(ioface, &buffer);
    try reader.interface.fillMore();
    const line = try reader.interface.takeDelimiter('\n');
    try std.testing.expectEqualStrings("root content", line.?);

    const parent_dir = try cwd.openDir(ioface, "../..", .{});
    const file2 = try parent_dir.openFile(ioface, "root.txt", .{ .mode = .read_only });
    var buffer2: [256]u8 = undefined;
    var reader2 = file2.reader(ioface, &buffer2);
    try reader2.interface.fillMore();
    const line2 = try reader2.interface.takeDelimiter('\n');
    try std.testing.expectEqualStrings("root content", line2.?);
}

test "absolute paths" {
    const fs = try TestFs.setup(std.testing.allocator);
    defer fs.deinit();

    try fs.createDir("data/config");
    try fs.createFile("/data/config/settings.json", "{\"key\": \"value\"}");

    try fs.setCwd("data");

    const ioface = fs.io();
    const cwd = Dir.cwd();

    const file = try cwd.openFile(ioface, "/data/config/settings.json", .{ .mode = .read_only });
    var buffer: [256]u8 = undefined;
    var reader = file.reader(ioface, &buffer);
    try reader.interface.fillMore();
    const content = reader.interface.buffered();
    try std.testing.expectEqualStrings("{\"key\": \"value\"}", content);

    const dir = try cwd.openDir(ioface, "/data/config", .{});
    const file2 = try dir.openFile(ioface, "settings.json", .{ .mode = .read_only });
    var buffer2: [256]u8 = undefined;
    var reader2 = file2.reader(ioface, &buffer2);
    try reader2.interface.fillMore();
    const content2 = reader2.interface.buffered();
    try std.testing.expectEqualStrings("{\"key\": \"value\"}", content2);
}

test "createDirAbsolute and createFileAbsolute" {
    const fs = try TestFs.setup(std.testing.allocator);
    defer fs.deinit();

    _ = try fs.setupRootDir("tmp");

    try fs.createDir("some/nested/path");
    try fs.setCwd("some/nested/path");

    const ioface = fs.io();

    try Dir.createDirAbsolute(ioface, "/tmp/mydir", .default_dir);
    const file = try Dir.createFileAbsolute(ioface, "/tmp/mydir/file.txt", .{});
    {
        var buffer: [256]u8 = undefined;
        var writer = file.writer(ioface, &buffer);
        try writer.interface.print("Created at absolute path", .{});
        try writer.interface.flush();
    }

    try std.testing.expect(fs.fileExists("/tmp/mydir/file.txt"));
    const content = try fs.readFile("/tmp/mydir/file.txt");
    try std.testing.expectEqualStrings("Created at absolute path", content);
}

test "root is read-only" {
    const fs = try TestFs.setup(std.testing.allocator);
    defer fs.deinit();

    const ioface = fs.io();
    const cwd = Dir.cwd();

    const result = cwd.createDirPath(ioface, "/toplevel/dir");
    try std.testing.expectError(error.ReadOnlyFileSystem, result);
}

test "File.Writer comprehensive" {
    const fs = try TestFs.setup(std.testing.allocator);
    defer fs.deinit();

    const ioface = fs.io();
    const cwd = Dir.cwd();

    const file = try cwd.createFile(ioface, "output.txt", .{});
    {
        var buffer: [64]u8 = undefined;
        var writer = file.writer(ioface, &buffer);

        try writer.interface.writeByte('H');
        try writer.interface.writeByte('i');
        try writer.interface.writeAll(" there!\n");
        try writer.interface.print("Number: {d}\n", .{42});
        try writer.interface.print("String: {s}\n", .{"test"});
        try writer.interface.flush();
    }

    const content = try fs.readFile("output.txt");
    try std.testing.expectEqualStrings("Hi there!\nNumber: 42\nString: test\n", content);
}

test "File.Reader comprehensive" {
    const fs = try TestFs.setup(std.testing.allocator);
    defer fs.deinit();

    try fs.createFile("input.txt", "Line 1\nLine 2\nLine 3\nEnd");

    const ioface = fs.io();
    const cwd = Dir.cwd();

    const file = try cwd.openFile(ioface, "input.txt", .{ .mode = .read_only });
    var buffer: [256]u8 = undefined;
    var reader = file.reader(ioface, &buffer);
    try reader.interface.fillMore();

    const line1 = try reader.interface.takeDelimiter('\n');
    try std.testing.expectEqualStrings("Line 1", line1.?);

    const line2 = try reader.interface.takeDelimiter('\n');
    try std.testing.expectEqualStrings("Line 2", line2.?);

    const line3 = try reader.interface.takeDelimiter('\n');
    try std.testing.expectEqualStrings("Line 3", line3.?);

    const remaining = reader.interface.buffered();
    try std.testing.expectEqualStrings("End", remaining);
}

test "File truncation with setLength" {
    const fs = try TestFs.setup(std.testing.allocator);
    defer fs.deinit();

    try fs.createFile("truncate.txt", "This is a long content that will be truncated");

    const ioface = fs.io();
    const cwd = Dir.cwd();

    const file = try cwd.openFile(ioface, "truncate.txt", .{ .mode = .write_only });
    try file.setLength(ioface, 7);

    const content = try fs.readFile("truncate.txt");
    try std.testing.expectEqualStrings("This is", content);
}

test "mixed cwd and absolute operations" {
    const fs = try TestFs.setup(std.testing.allocator);
    defer fs.deinit();

    _ = try fs.setupRootDir("tmp");
    try fs.createDir("/tmp/cache");
    try fs.createFile("/tmp/cache/data.bin", "cached");

    try fs.createDir("workspace/project/src");
    try fs.setCwd("workspace/project/src");

    const ioface = fs.io();
    const cwd = Dir.cwd();

    const cache_file = try std.Io.Dir.openFileAbsolute(ioface, "/tmp/cache/data.bin", .{ .mode = .read_only });
    var buffer: [64]u8 = undefined;
    var reader = cache_file.reader(ioface, &buffer);
    try reader.interface.fillMore();
    try std.testing.expectEqualStrings("cached", reader.interface.buffered());

    const src_file = try cwd.createFile(ioface, "main.zig", .{});
    {
        var write_buffer: [256]u8 = undefined;
        var writer = src_file.writer(ioface, &write_buffer);
        try writer.interface.print("pub fn main() void {{}}", .{});
        try writer.interface.flush();
    }

    const content = try fs.readFile("main.zig");
    try std.testing.expectEqualStrings("pub fn main() void {}", content);
    try std.testing.expect(fs.fileExists("main.zig"));
}

test "Dir.openDirAbsolute" {
    const fs = try TestFs.setup(std.testing.allocator);
    defer fs.deinit();

    try fs.createDir("project/src/lib");

    const ioface = fs.io();
    const dir = try Dir.openDirAbsolute(ioface, "/home/test/project", .{});
    const subdir = try dir.openDir(ioface, "src", .{});
    const lib = try subdir.openDir(ioface, "lib", .{});
    _ = lib;
}

test "File.sync" {
    const fs = try TestFs.setup(std.testing.allocator);
    defer fs.deinit();

    const ioface = fs.io();
    const cwd = Dir.cwd();

    const file = try cwd.createFile(ioface, "synctest.txt", .{});
    {
        var buffer: [256]u8 = undefined;
        var writer = file.writer(ioface, &buffer);
        try writer.interface.print("data to sync", .{});
        try writer.interface.flush();
    }
    try file.sync(ioface);
    file.close(ioface);

    const content = try fs.readFile("synctest.txt");
    try std.testing.expectEqualStrings("data to sync", content);
}

test "Dir.access" {
    const fs = try TestFs.setup(std.testing.allocator);
    defer fs.deinit();

    try fs.createFile("exists.txt", "content");
    try fs.createDir("existsdir");

    const ioface = fs.io();
    const cwd = Dir.cwd();

    try cwd.access(ioface, "exists.txt", .{});
    try cwd.access(ioface, "existsdir", .{});

    const result = cwd.access(ioface, "nonexistent.txt", .{});
    try std.testing.expectError(error.FileNotFound, result);
}

test "stdin streamDelimiterLimit" {
    const fs = try TestFs.setup(std.testing.allocator);
    defer fs.deinit();

    fs.setStdin("{\"jsonrpc\":\"2.0\",\"method\":\"test\"}\n{\"jsonrpc\":\"2.0\",\"method\":\"second\"}\n");

    const ioface = fs.io();
    const stdin = File.stdin();

    var read_buffer: [1024]u8 = undefined;
    var reader = stdin.reader(ioface, &read_buffer);

    var line1_buffer: [1024]u8 = undefined;
    var line1_writer = Io.Writer.fixed(&line1_buffer);
    const len1 = try reader.interface.streamDelimiterLimit(&line1_writer, '\n', @enumFromInt(1024));
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"method\":\"test\"}", line1_buffer[0..len1]);
    reader.interface.toss(1);

    var line2_buffer: [1024]u8 = undefined;
    var line2_writer = Io.Writer.fixed(&line2_buffer);
    const len2 = try reader.interface.streamDelimiterLimit(&line2_writer, '\n', @enumFromInt(1024));
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"method\":\"second\"}", line2_buffer[0..len2]);
}
