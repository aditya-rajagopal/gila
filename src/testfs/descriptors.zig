const std = @import("std");

const handle_mod = @import("handle.zig");
const Handle = handle_mod.Handle;

pub const Descriptor = union(enum) {
    file: *VirtualFile,
    directory: *VirtualDir,

    pub fn name(self: Descriptor) []const u8 {
        return switch (self) {
            .file => |f| f.name,
            .directory => |d| d.name,
        };
    }

    pub fn handle(self: Descriptor) Handle {
        return switch (self) {
            .file => |f| f.handle,
            .directory => |d| d.handle,
        };
    }
};

pub const VirtualFile = struct {
    name: []const u8,
    content: std.ArrayList(u8),
    allocator: std.mem.Allocator,
    handle: Handle,
    parent: ?*VirtualDir,
    read_pos: usize = 0,

    pub fn create(allocator: std.mem.Allocator, vname: []const u8, vhandle: Handle, parent: ?*VirtualDir) !*VirtualFile {
        const file = try allocator.create(VirtualFile);
        file.* = .{
            .name = try allocator.dupe(u8, vname),
            .content = .{},
            .allocator = allocator,
            .handle = vhandle,
            .parent = parent,
            .read_pos = 0,
        };
        return file;
    }

    pub fn destroy(self: *VirtualFile, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.content.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn write(self: *VirtualFile, data: []const u8) !void {
        try self.content.appendSlice(self.allocator, data);
    }

    pub fn read(self: *VirtualFile, buffer: []u8) usize {
        const available = self.content.items.len - self.read_pos;
        if (available == 0) return 0;

        const to_read = @min(buffer.len, available);
        @memcpy(buffer[0..to_read], self.content.items[self.read_pos..][0..to_read]);
        self.read_pos += to_read;
        return to_read;
    }

    pub fn truncate(self: *VirtualFile, len: u64) void {
        if (len == 0) {
            self.content.clearRetainingCapacity();
        } else if (len < self.content.items.len) {
            self.content.shrinkRetainingCapacity(@intCast(len));
        }
        self.read_pos = 0;
    }

    pub fn resetReadPos(self: *VirtualFile) void {
        self.read_pos = 0;
    }
};

pub const VirtualDir = struct {
    name: []const u8,
    entries: std.StringHashMap(Descriptor),
    handle: Handle,
    parent: ?*VirtualDir,
    iter_keys: ?[][]const u8 = null,
    iter_index: usize = 0,

    pub fn create(allocator: std.mem.Allocator, vname: []const u8, vhandle: Handle, parent: ?*VirtualDir) !*VirtualDir {
        const dir = try allocator.create(VirtualDir);
        dir.* = .{
            .name = try allocator.dupe(u8, vname),
            .entries = std.StringHashMap(Descriptor).init(allocator),
            .handle = vhandle,
            .parent = parent,
            .iter_keys = null,
            .iter_index = 0,
        };
        return dir;
    }

    pub fn destroy(self: *VirtualDir, allocator: std.mem.Allocator) void {
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            switch (entry.value_ptr.*) {
                .file => |f| f.destroy(allocator),
                .directory => |d| d.destroy(allocator),
            }
        }
        self.entries.deinit();
        if (self.iter_keys) |keys| {
            allocator.free(keys);
        }
        allocator.free(self.name);
        allocator.destroy(self);
    }

    pub fn addEntry(self: *VirtualDir, entry: Descriptor) !void {
        try self.entries.put(entry.name(), entry);
        if (self.iter_keys) |keys| {
            self.entries.allocator.free(keys);
            self.iter_keys = null;
        }
    }

    pub fn getEntry(self: *VirtualDir, entry_name: []const u8) ?Descriptor {
        return self.entries.get(entry_name);
    }

    pub fn removeEntry(self: *VirtualDir, entry_name: []const u8) bool {
        if (self.entries.fetchRemove(entry_name)) |_| {
            if (self.iter_keys) |keys| {
                self.entries.allocator.free(keys);
                self.iter_keys = null;
            }
            return true;
        }
        return false;
    }

    pub fn prepareIteration(self: *VirtualDir, allocator: std.mem.Allocator) !void {
        if (self.iter_keys != null) return;

        const keys = try allocator.alloc([]const u8, self.entries.count());
        var i: usize = 0;
        var iter = self.entries.keyIterator();
        while (iter.next()) |key| {
            keys[i] = key.*;
            i += 1;
        }
        self.iter_keys = keys;
        self.iter_index = 0;
    }

    pub fn nextEntry(self: *VirtualDir) ?Descriptor {
        const keys = self.iter_keys orelse return null;
        if (self.iter_index >= keys.len) return null;

        const key = keys[self.iter_index];
        self.iter_index += 1;
        return self.entries.get(key);
    }

    pub fn resetIteration(self: *VirtualDir) void {
        self.iter_index = 0;
    }
};

pub fn resolvePath(root: *VirtualDir, base_dir: ?*VirtualDir, path: []const u8) ?Descriptor {
    if (path.len == 0) {
        if (base_dir) |bd| {
            return .{ .directory = bd };
        }
        return .{ .directory = root };
    }

    const is_absolute = path[0] == '/';
    var current: *VirtualDir = if (is_absolute) root else (base_dir orelse root);

    var path_iter = std.mem.splitScalar(u8, path, '/');
    while (path_iter.next()) |component| {
        if (component.len == 0) continue;

        if (std.mem.eql(u8, component, ".")) continue;

        if (std.mem.eql(u8, component, "..")) {
            current = current.parent orelse root;
            continue;
        }

        const entry = current.getEntry(component) orelse return null;

        if (path_iter.peek() == null) {
            return entry;
        }

        switch (entry) {
            .directory => |d| current = d,
            .file => return null,
        }
    }

    return .{ .directory = current };
}

pub fn resolveParentAndName(root: *VirtualDir, base_dir: ?*VirtualDir, path: []const u8) ?struct { parent: *VirtualDir, name: []const u8 } {
    if (path.len == 0) return null;

    const is_absolute = path[0] == '/';
    const last_slash = std.mem.lastIndexOfScalar(u8, path, '/');

    if (last_slash) |idx| {
        const parent_path = if (idx == 0 and is_absolute) "/" else path[0..idx];
        const file_name = path[idx + 1 ..];

        if (file_name.len == 0) return null;

        if (std.mem.eql(u8, parent_path, "/")) {
            return .{ .parent = root, .name = file_name };
        }

        const parent_entry = resolvePath(root, base_dir, parent_path) orelse return null;
        switch (parent_entry) {
            .directory => |d| return .{ .parent = d, .name = file_name },
            .file => return null,
        }
    } else {
        return .{
            .parent = base_dir orelse root,
            .name = path,
        };
    }
}
