const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const builtin = @import("builtin");

const gila = @import("gila");
const stdx = @import("stdx");
const root = @import("root");
const tuig = @import("tuig");
const Terminal = tuig.Terminal;
const TerminalConfig = tuig.TerminalConfig;
const Renderer = tuig.renderer.Renderer;
const e = tuig.event;
const Code = tuig.event.KeyEvent.Code;

const common = @import("common.zig");

const log = std.log.scoped(.pick);

const Pick = @This();

verbose: bool = false,
owners: ?common.StringList = null,
priority: ?common.PriorityFilter = null,
priority_value: ?common.PriorityValueFilter = null,
tags: ?common.TagsFilter = null,
waiting_on: ?common.WaitingOnFilter = null,
fields: ?common.StringList = null,

pub fn execute(self: Pick, ctx: common.CommandContext) void {
    if (!self.verbose) {
        root.log_level = .warn;
    }
    self.run(ctx) catch |err| switch (err) {
        error.GilaNotFound => log.err("GILA directory not found. Run 'gila init' first.", .{}),
        error.OutOfMemory => log.err("Failed to allocate memory", .{}),
        error.DirIterationFailed => log.err("Failed to iterate over gila directory", .{}),
        error.FailedToGenerateTaskId => log.err("Failed to generate task id", .{}),
        error.InvalidTask => log.err("Invalid task", .{}),
        error.FailedToWriteTaskDescriptionFile => log.err("Failed to write task description file", .{}),
        error.FailedToOpenEditor => log.err("Failed to open editor", .{}),
        error.SyncFailed => log.err("Failed to synchronize tasks", .{}),
        error.NoTasksFound => log.err("No tasks found", .{}),
    };
}

pub const Error = error{
    GilaNotFound,
    OutOfMemory,
    DirIterationFailed,
    FailedToGenerateTaskId,
    InvalidTask,
    FailedToWriteTaskDescriptionFile,
    FailedToOpenEditor,
    SyncFailed,
    NoTasksFound,
};

const FoundTask = struct {
    task: gila.Task,
    file: []const u8,
};

pub fn run(self: Pick, ctx: common.CommandContext) !void {
    const io = ctx.io;
    const arena = ctx.arena;
    const allocator = arena.allocator();
    _, var gila_dir = common.getGilaDir(io, allocator) orelse return Error.GilaNotFound;
    defer gila_dir.close(io);

    const Find = @import("find.zig");
    // @TODO GILA(aweful_pyro_5y7)
    const todo = Find{
        .status = .todo,
        .owners = self.owners,
        .priority = self.priority,
        .priority_value = self.priority_value,
        .tags = self.tags,
        .waiting_on = self.waiting_on,
        .verbose = self.verbose,
    };
    const results = try todo.run(ctx);
    if (results.tasks.len == 0) {
        return Error.NoTasksFound;
    }
    var found_tasks = try std.ArrayList(FoundTask).initCapacity(allocator, results.tasks.len);
    const task_buffer: []u8 = try allocator.alloc(u8, 64 * 1024);
    var local_arena = stdx.Arena.initBuffer(task_buffer);
    var count: usize = 0;
    for (results.tasks) |entry| {
        _ = local_arena.reset(false);
        const task_file = gila_dir.openFile(io, entry.path, .{ .mode = .read_only }) catch continue;
        defer task_file.close(io);
        const last_slash = std.mem.lastIndexOfScalar(u8, entry.path, '/') orelse continue;
        var task: gila.Task = gila.Task.init(entry.path[last_slash + 1 .. entry.path.len - 3]) catch unreachable;
        task.fromFile(task_file, io, &local_arena) catch continue;

        const task_copy = task.dupe(allocator, .{ .owner = true, .id = true, .tags = true, .title = true }) catch continue;
        found_tasks.append(allocator, .{ .task = task_copy, .file = entry.path }) catch continue;
        count += 1;
    }

    const lessThan = struct {
        pub fn lessThan(_: void, a: FoundTask, b: FoundTask) bool {
            if (@intFromEnum(a.task.priority) < @intFromEnum(b.task.priority)) return false else if (@intFromEnum(a.task.priority) > @intFromEnum(b.task.priority)) return true;
            if (a.task.priority_value < b.task.priority_value) return false;
            return false;
        }
    }.lessThan;
    std.sort.heap(FoundTask, found_tasks.items, {}, lessThan);

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(ctx.io, &buffer);

    writer.interface.writeAll("Tasks found:\n") catch unreachable;
    writer.interface.print("|{s:^20}|{s:^8}|{s:^14}|{s}\n", .{ "ID", "Priority", "Priority Value", "Title" }) catch unreachable;
    for (found_tasks.items) |entry| {
        writer.interface.print("|{s:^20}|{t:^8}|{d:^14}|{s}\n", .{ entry.task.id, entry.task.priority, entry.task.priority_value, entry.task.title }) catch unreachable;
    }

    writer.interface.flush() catch unreachable;

    var write_buffer: [4096]u8 align(4096) = undefined;
    var config: TerminalConfig = .tui_default;
    config.mouse.?.sgr = false;
    var terminal = Terminal.init(io, config, &write_buffer) catch |err| {
        log.err("Failed to initialize terminal: {s}", .{@errorName(err)});
        return;
    };
    defer terminal.deinit();
    root.global_tty = &terminal;

    terminal.setCursorVisible(false) catch {};
    defer terminal.setCursorVisible(true) catch {};

    var quit = false;
    var app = Application.init(&terminal, found_tasks.items);
    var renderer: Renderer = undefined;
    renderer.init(&terminal, std.heap.page_allocator) catch {
        log.err("Failed to initialize renderer", .{});
        return;
    };

    while (!quit) {
        const events = terminal.pollEvents(16) catch {
            log.err("Failed to poll events", .{});
            return;
        };

        renderer.beginFrame(events);
        defer renderer.endFrame();

        quit = app.updateAndRender(events, &renderer);
    }
}

const Application = struct {
    screen_position: usize = 0,
    task_start: usize = 0,
    task_end: usize = 0,
    lines: usize = 0,
    result: []FoundTask = undefined,
    mode: Mode = .tasklist,
    splash_progress: u16 = 0,

    const Mode = enum { tasklist };
    const Result = enum { success, quit, scene_change };

    pub fn init(terminal: *Terminal, tasks: []FoundTask) Application {
        var application = Application{
            .lines = terminal.size.height - 1,
        };
        application.result = tasks;
        application.task_end = std.math.clamp(application.result.len, 0, application.lines);
        application.splash_progress = 0;
        return application;
    }

    fn updateAndRender(self: *Application, events: []const e.Event, renderer: *Renderer) bool {
        const result: Result = .scene_change;
        loop: switch (result) {
            .scene_change => switch (self.mode) {
                .tasklist => continue :loop self.taskList(events, renderer),
            },
            .quit => return true,
            .success => return false,
        }
    }

    fn taskList(self: *Application, events: []const e.Event, renderer: *Renderer) Result {
        var direction: i8 = 0;
        {
            for (events) |event| {
                switch (event) {
                    .key_pressed, .key_repeat => |key| {
                        switch (key.physical_key) {
                            .q => return .quit,
                            .j, .down => direction = 1,
                            .k, .up => direction = -1,
                            else => {},
                        }
                    },
                    .mouse_scroll_up => {
                        direction = 1;
                    },
                    .mouse_scroll_down => {
                        direction = -1;
                    },
                    .resize => |resize| {
                        const lines_before = self.lines;
                        self.lines = resize.height - 1;
                        if (lines_before > self.lines) {
                            if (self.result.len < lines_before) {
                                const lines_empty_before = lines_before - self.result.len;
                                const lines_reduced = lines_before - self.lines;
                                if (lines_empty_before > lines_reduced) {} else {
                                    self.task_end -= (lines_reduced - lines_empty_before);
                                }
                            } else {
                                if (self.screen_position >= self.lines) {
                                    self.task_end -= lines_before - 1 - self.screen_position;
                                    self.task_start = self.task_end - self.lines;
                                    self.screen_position = self.lines - 1;
                                } else {
                                    self.task_end -= (lines_before - self.lines);
                                }
                            }
                        } else {
                            if (self.result.len <= self.lines) {
                                self.task_start = 0;
                                self.task_end = self.result.len;
                            } else {
                                const tasks_remaining = self.result.len - self.task_end;
                                const lines_added = self.lines - lines_before;
                                if (tasks_remaining < lines_added) {
                                    self.task_end += tasks_remaining;
                                    self.task_start -= lines_added - tasks_remaining;
                                    self.screen_position += lines_added - tasks_remaining;
                                } else {
                                    self.task_end += lines_added;
                                }
                            }
                        }
                    },
                    else => {},
                }
            }
        }

        {
            if (direction == -1) {
                if (self.screen_position == 0) {
                    if (self.task_start == 0) {
                        if (self.result.len > self.lines) {
                            self.task_end = self.result.len;
                            self.task_start = self.result.len - self.lines;
                            self.screen_position = self.lines - 1;
                        } else {
                            self.screen_position = self.result.len;
                        }
                    } else {
                        self.task_start -= 1;
                        self.task_end -= 1;
                    }
                } else {
                    self.screen_position -= 1;
                }
            }

            if (direction == 1) {
                if (self.screen_position == self.lines - 1) {
                    if (self.task_end == self.result.len) {
                        self.task_end = self.lines;
                        self.task_start = 0;
                        self.screen_position = 0;
                    } else {
                        self.task_start += 1;
                        self.task_end += 1;
                    }
                } else if (self.screen_position == self.result.len) {
                    self.screen_position = 0;
                } else {
                    self.screen_position += 1;
                }
            }

            var buf: [1024]u8 = undefined;
            var str = std.fmt.bufPrint(
                &buf,
                " |{s:^20}|{s:^8}|{s:^14}|{s}\n",
                .{ "ID", "Priority", "Priority Value", "Title" },
            ) catch unreachable;
            _ = renderer.render_buffer.renderTextDelimiter(0, 0, str, null, null);
            for (self.result[self.task_start..self.task_end], 0..) |entry, index| {
                str = std.fmt.bufPrint(
                    &buf,
                    "{s}|{s:^20}|{t:^8}|{d:^14}|{s}\n",
                    .{
                        if (self.screen_position == index) ">" else " ",
                        entry.task.id,
                        entry.task.priority,
                        entry.task.priority_value,
                        entry.task.title,
                    },
                ) catch unreachable;
                _ = renderer.render_buffer.renderTextDelimiter(0, @truncate(index + 1), str, null, null);
            }
        }
        return .success;
    }
};
