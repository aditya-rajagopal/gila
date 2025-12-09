//! This file provides a very simple argument parser for zig.
//!
//! It is pretty much taken from the tigerbeetle project.
//! https://github.com/tigerbeetle/tigerbeetle/blob/16d62f0ce7d4ef3db58714c9b7a0c46480c19bc3/src/flags.zig
//!
//! I modified to fit my needs and my coding style and, subjectively, made it better for me.
//! eg.
//! * I removed a lot of comptime asserts and made them @compileError's instead as I prefer the more human readable error messages
//! * I added help flags to commands in addition to the help flag for the program
//! * I prefer the zig style nameing convention for function names as i like to do things like `const default_value = defaultValue(xyz);`
//! * Added floating point numbers
//!
//! error messages.

// @TODO: Add tests
const std = @import("std");
const assert = std.debug.assert;

const log = std.log.scoped(.args_parser);

const MAX_ARGS = 128;

/// Parse CLI arguments for subcommands specified as Zig `struct` or `union(enum)`:
///
/// ```
/// const CLIArgs = union(enum) {
///    init: struct {
///        bare: bool = false,
///        positional: struct {
///            directory: ?[]const u8 = null,
///        },
///
///        pub const help =
///            \\Usage: program init [--bare] [<directory>]
///            \\
///            \\Description
///            \\
///            \\Options:
///            \\  --bare  Creates a bare project without subfolders and tracking files.
///            \\  <directory>  The directory to initialize the project in. Defaults to the current directory.
///            \\
///         ;
///    },
///
///    pub const help =
///        \\Usage:
///        \\
///        \\    program [-h | --help]
///        \\
///        \\    program init [-h | --help] [--bare] [<directory>]
///        \\
///        \\Commands:
///        \\    init  Initializes a new program project in the current directory or the specified directory.
///        \\
///        \\Options:
///        \\    -h, --help
///        \\        Prints this help message.
///        \\
///     ;
/// }
///
/// const cli_args: CLIArgs = parse_commands(&args, CLIArgs);
/// ```
///
/// `positional` field is treated specially, it designates positional arguments.
///
/// If `pub const help` declaration is present, it is used to implement `-h/--help` argument.
///
/// @TODO Value parsing can be customized on per-type basis via `parse_flag_value` customization point.
/// @TODO More documentation for the requirements of `ArgType`.
pub fn parseArgs(args: *std.process.ArgIterator, comptime ArgType: type) ArgType {
    // @NOTE: Skip the first argument, which is the program name.
    assert(args.skip());
    return parseFlags(args, ArgType);
}

fn parseCommand(args: *std.process.ArgIterator, comptime Command: type) Command {
    const info = @typeInfo(Command);
    if (info != .@"union") {
        @compileError("Expected union type, found '" ++ @typeName(Command) ++ "' when parsing command");
    }

    const command: []const u8 = args.next() orelse {
        // @TODO print help
        if (@hasDecl(Command, "help")) {
            var interface = std.fs.File.stdout().writer(&.{}).interface;
            interface.writeAll(Command.help) catch std.process.exit(1);
            interface.writeAll("\n") catch std.process.exit(1);
        }
        logFatal("Expected a command", .{});
    };

    // @NOTE If you want to add a help flag to your command, add the following to the command struct:
    // pub const help =
    //     \\Usage: command [--help]
    //     \\
    //     \\Description of the command.
    //     \\
    //     \\Options:
    //     \\  --help  Prints this help message.
    // ;
    //
    // It ***MUST*** be a marked pub to be visable to print.
    if (@hasDecl(Command, "help")) {
        if (std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "--help")) {
            var interface = std.fs.File.stdout().writer(&.{}).interface;
            interface.writeAll(Command.help) catch std.process.exit(1);
            std.process.exit(0);
        }
    }

    inline for (info.@"union".fields) |field| {
        if (std.mem.eql(u8, field.name, command)) {
            return @unionInit(
                Command,
                field.name,
                parseFlags(args, field.type),
            );
        }
    }
    logFatal("Unknown command '{s}'", .{command});
    unreachable;
}

fn parseFlags(args: *std.process.ArgIterator, comptime Flags: type) Flags {
    if (Flags == void) {
        if (args.next()) |arg| {
            logFatal("Unexpected argument '{s}'", .{arg});
        }
        return {};
    }

    if (@typeInfo(Flags) == .@"union") {
        return parseCommand(args, Flags);
    }

    if (@typeInfo(Flags) != .@"struct") {
        @compileError("Expected struct type, found '" ++ @typeName(Flags) ++ "' when parsing flags");
    }

    comptime var parsed_fields = parseStructFields(Flags);

    // @NOTE We can have flags with the same prefix like --foo-bar and --foo. So to make sure we parse them correctly
    // We need to sort the fields by longest name first so that we can check if the given argument is a prefix of a flag.
    // This way we ensure that when we check against --foo we have already checked against --foo-bar.
    comptime std.mem.sort(Type.StructField, parsed_fields.fields[0..parsed_fields.field_count], {}, struct {
        fn lessThan(context: void, l: Type.StructField, r: Type.StructField) bool {
            _ = context;
            const lhs = comptime std.mem.span(l.name.ptr);
            const rhs = comptime std.mem.span(r.name.ptr);

            if (lhs.len > rhs.len) {
                return true;
            } else if (lhs.len < rhs.len) {
                return false;
            }
            const n = @min(lhs.len, rhs.len);
            for (lhs[0..n], rhs[0..n]) |lhs_elem, rhs_elem| {
                switch (std.math.order(lhs_elem, rhs_elem)) {
                    .eq => continue,
                    .lt => return false,
                    .gt => return true,
                }
            }
            return std.math.order(lhs.len, rhs.len) == .gt;
        }
    }.lessThan);

    // @NOTE We need to store if, while parsing the fields, we encountered a particular flag or not. We can set the fields
    // that did not recieve an argument to their default values and also catch multiple entries for the same flag.
    var counts = comptime blk: {
        var count_fields = std.meta.fields(Flags)[0..std.meta.fields(Flags).len].*;
        for (&count_fields) |*field| {
            field.type = u32;
            field.alignment = @alignOf(u32);
            field.default_value_ptr = @ptrCast(&@as(u32, 0));
        }
        break :blk @Type(.{
            .@"struct" = .{
                .layout = .auto,
                .fields = &count_fields,
                .decls = &.{},
                .is_tuple = false,
            },
        }){};
    };

    const flag_names = comptime blk: {
        var names: [parsed_fields.field_count][]const u8 = undefined;
        for (parsed_fields.fields[0..parsed_fields.field_count], 0..) |field, i| {
            var name: []const u8 = "--";
            var index: usize = 0;
            while (std.mem.findScalar(u8, field.name[index..], '_')) |pos| {
                name = name ++ field.name[index..][0..pos] ++ "-";
                index += pos + 1;
            }
            name = name ++ field.name[index..];
            names[i] = name;
        }
        break :blk names;
    };

    var parsed_positional: bool = false;
    var result: Flags = undefined;

    var parsed_args: usize = 0;

    parsing_next_arg: for (0..MAX_ARGS) |_| {
        const arg = args.next() orelse break :parsing_next_arg;
        if (@hasDecl(Flags, "help") and parsed_args == 0) {
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                var interface = std.fs.File.stdout().writer(&.{}).interface;
                interface.writeAll(Flags.help) catch std.process.exit(1);
                interface.writeAll("\n") catch std.process.exit(1);
                std.process.exit(0);
            }
        }
        comptime var field_length_previous: usize = std.math.maxInt(usize);
        inline for (parsed_fields.fields[0..parsed_fields.field_count], 0..) |field, index| {
            comptime assert(field_length_previous >= field.name.len);
            field_length_previous = field.name.len;

            if (std.mem.startsWith(u8, arg, flag_names[index])) {
                if (parsed_positional) {
                    logFatal("Unexpected argument '{s}' after positional arguments", .{arg});
                }
                @field(counts, field.name) += 1;
                const value = parseFlag(field.type, flag_names[index], arg);
                @field(result, field.name) = value;
                parsed_args += 1;
                continue :parsing_next_arg;
            }
        }
        if (@hasField(Flags, "positional")) {
            counts.positional += 1;
            switch (counts.positional - 1) {
                inline 0...parsed_fields.positional_fields.len - 1 => |index| {
                    const positional_field = parsed_fields.positional_fields[index];
                    if (comptime std.mem.findScalar(u8, positional_field.name, '_') != null) {
                        @compileError("Positional field '" ++ positional_field.name ++ "' in struct '" ++ @typeName(Flags) ++ "' must have no underscores.");
                    }
                    if (arg.len == 0) {
                        logFatal("Positional argument <{s}> is missing", .{positional_field.name});
                    }
                    if (arg[0] == '-') {
                        logFatal("Unexpected argument '{s}'", .{arg});
                    }
                    parsed_positional = true;
                    @field(result.positional, positional_field.name) = parseFlagValue(positional_field.type, "positional." ++ positional_field.name, arg, true);

                    continue :parsing_next_arg;
                },
                else => {
                    // @NOTE This will cause excess posistional arguments to fall through to the error as it is essentially an unexpected argument
                },
            }
        }
        logFatal("Unexpected argument '{s}'", .{arg});
    } else {
        logFatal("Struct '{s}' has too many fields. Current maximum is {d}. If you really need more(why) just increase MAX_ARGS in flags.zig", .{
            @typeName(Flags),
            MAX_ARGS,
        });
    }

    // @NOTE We now go through all the fields and check if any have not been set and set them to their default values.
    inline for (parsed_fields.fields[0..parsed_fields.field_count], 0..) |field, i| {
        const flag_name = flag_names[i];
        switch (@field(counts, field.name)) {
            0 => {
                if (defaultValue(field)) |v| {
                    @field(result, field.name) = v;
                } else {
                    logFatal("Flag '{s}' is required", .{flag_name});
                }
            },
            1 => {},
            else => {
                // @TODO Should this be allowed and the last value be used?
                logFatal("Flag '{s}' is specified multiple times", .{flag_name});
            },
        }
    }

    if (@hasField(Flags, "positional")) {
        assert(counts.positional <= parsed_fields.positional_fields.len);
        inline for (parsed_fields.positional_fields, 0..) |positional_field, index| {
            if (index >= counts.positional) {
                if (defaultValue(positional_field)) |v| {
                    @field(result.positional, positional_field.name) = v;
                } else {
                    logFatal("Positional argument <{s}> is required", .{positional_field.name});
                }
            }
        }
    }

    return result;
}

fn parseFlag(comptime Flag: type, flag_name: []const u8, arg: [:0]const u8) Flag {
    assert(flag_name[0] == '-');
    assert(flag_name[1] == '-');
    assert(std.mem.startsWith(u8, arg, flag_name));

    if (Flag == bool) {
        if (std.mem.eql(u8, flag_name, arg)) {
            return true;
        } else {
            logFatal("Boolean flag '{s}' requires no argument", .{flag_name});
        }
    }

    const value: [:0]const u8 = split_value: {
        var result = arg[flag_name.len..];
        if (result.len == 0) {
            logFatal("Flag '{s}' requires an argument, but none was provided", .{flag_name});
        }
        if (result[0] == '=') {
            result = result[1..];
        } else {
            logFatal("Flag '{s}': expected '=' after argument but found '{c}' in '{s}'", .{ flag_name, result[0], arg });
        }

        if (result.len == 0) {
            logFatal("Flag '{s}': no result provided after '=' in '{s}'", .{ flag_name, arg });
        }
        break :split_value result;
    };
    return parseFlagValue(Flag, flag_name, value, false);
}

fn parseFlagValue(comptime Flag: type, flag_name: []const u8, flag_value: [:0]const u8, comptime is_positional: bool) Flag {
    assert((flag_name[0] == '-' and flag_name[1] == '-') or is_positional);
    assert(flag_value.len > 0);
    assert(Flag != bool);

    const Value = switch (@typeInfo(Flag)) {
        .optional => |info| info.child,
        else => Flag,
    };

    if (Value == []const u8 or Value == [:0]const u8) {
        return flag_value;
    }

    if (@typeInfo(Value) == .int) {
        return std.fmt.parseInt(Value, flag_value, 10) catch |err| switch (err) {
            error.Overflow => logFatal("Flag '{s}': value '{s}' exceeds bounds of type '{s}'", .{ flag_name, flag_value, @typeName(Value) }),
            error.InvalidCharacter => logFatal("Flag '{s}': value '{s}' is not a valid integer literal", .{ flag_name, flag_value }),
            else => unreachable,
        };
    }

    if (@typeInfo(Value) == .float) {
        return std.fmt.parseFloat(Value, flag_value) catch |err| switch (err) {
            error.InvalidCharacter => logFatal("Flag '{s}': value '{s}' is not a valid float literal", .{ flag_name, flag_value }),
            else => unreachable,
        };
    }

    if (@typeInfo(Value) == .@"enum") {
        comptime assert(@typeInfo(Value).@"enum".is_exhaustive);

        return std.meta.stringToEnum(Value, flag_value) orelse {
            const valid_values = comptime blk: {
                var valid_values: []const u8 = &.{};
                for (@typeInfo(Value).@"enum".fields) |field| {
                    valid_values = valid_values ++ "\n" ++ field.name ++ ",";
                }
                break :blk valid_values;
            };
            logFatal(
                "Flag '{s}': value '{s}' is not a valid enum literal of type '{s}'. Valid values are: {s}",
                .{ flag_name, flag_value, @typeName(Value), valid_values },
            );
        };
    }

    comptime unreachable;
}

const Type = std.builtin.Type;
fn parseStructFields(comptime Flags: type) struct {
    fields: [std.meta.fields(Flags).len]Type.StructField,
    field_count: usize,
    positional_fields: []const Type.StructField,
} {
    const info = @typeInfo(Flags).@"struct";
    comptime var fields: [info.fields.len]Type.StructField = undefined;
    comptime var field_count: usize = 0;
    comptime var positional_fields: []const Type.StructField = &.{};
    for (info.fields) |field| {
        if (std.mem.eql(u8, field.name, "positional")) {
            if (@typeInfo(field.type) != .@"struct") {
                @compileError("Positional field '" ++ field.name ++ "' in struct '" ++ @typeName(Flags) ++ "' must be a struct type.");
            }
            positional_fields = @typeInfo(field.type).@"struct".fields;
            var found_first_optional_with_no_default_value: bool = false;

            for (positional_fields) |positional_field| {
                const default_value = defaultValue(positional_field);
                if (defaultValue(positional_field)) |_| {
                    found_first_optional_with_no_default_value = true;
                } else {
                    // @NOTE Like in python functions, values with no defaults cannot follow fields with defaults.
                    if (found_first_optional_with_no_default_value) {
                        @compileError("Positional field '" ++ positional_field.name ++ "' in struct '" ++ @typeName(field.type) ++ "' has no default value but follows fields that have defaults. Like in python functions, fields with no defaults cannot follow fields with defaults.");
                    }
                }

                switch (@typeInfo(positional_field.type)) {
                    .optional => {
                        // @NOTE Optionals must have a default value and the default value must be null
                        if (default_value) |v| {
                            if (v != null) {
                                @compileError("Optional field '" ++ positional_field.name ++ "' in struct '" ++ @typeName(Flags) ++ ".positional' must have a default `null` value.");
                            }
                        } else {
                            @compileError("Optional field '" ++ positional_field.name ++ "' in struct '" ++ @typeName(Flags) ++ ".positional' must have a default `null` value.");
                        }
                    },
                    else => {},
                }

                checkField(positional_field, field.type);
            }

            continue;
        }
        fields[field_count] = field;
        field_count += 1;

        switch (@typeInfo(field.type)) {
            .bool => {
                // @NOTE Bools must have a default value and the default value must be false
                const default_value = defaultValue(field);
                if (default_value) |v| {
                    if (v != false) {
                        @compileError("Boolean field '" ++ field.name ++ "' in struct '" ++ @typeName(Flags) ++ "' must have a default `false` value.");
                    }
                } else {
                    @compileError("Boolean field '" ++ field.name ++ "' in struct '" ++ @typeName(Flags) ++ "' must have a default `false` value.");
                }
            },
            .optional => {
                // @NOTE Optionals must have a default value and the default value must be null
                const default_value = defaultValue(field);

                if (default_value) |v| {
                    if (v != null) {
                        @compileError("Optional field '" ++ field.name ++ "' in struct '" ++ @typeName(Flags) ++ "' must have a default `null` value.");
                    }
                } else {
                    @compileError("Optional field '" ++ field.name ++ "' in struct '" ++ @typeName(Flags) ++ "' must have a default `null` value.");
                }

                checkField(field, Flags);
            },
            else => {
                checkField(field, Flags);
            },
        }
    }
    return .{
        .fields = fields,
        .field_count = field_count,
        .positional_fields = positional_fields,
    };
}

fn checkField(comptime field: std.builtin.Type.StructField, @"struct": type) void {
    if (field.type == []const u8 or @typeInfo(field.type) == .int or @typeInfo(field.type) == .float) {
        return;
    }

    if (@typeInfo(field.type) == .@"enum") {
        const info = @typeInfo(field.type).@"enum";
        if (!info.is_exhaustive) {
            @compileError("Field '" ++ field.name ++ "' in struct '" ++ @typeName(@"struct") ++ "' of type '" ++ @typeName(field.type) ++ "' must have an exhaustive Enum type.");
        }
        if (info.fields.len < 2) {
            const err = std.fmt.comptimePrint("Field '" ++ field.name ++ "' in struct '" ++ @typeName(@"struct") ++ "' of type '" ++ @typeName(field.type) ++ "' must have at least 2 possible enum values. Has {}", .{info.fields.len});
            @compileError(err);
        }
        return;
    }

    if (@typeInfo(field.type) == .optional) {
        const info = @typeInfo(field.type).optional;
        const child = @typeInfo(info.child);

        if (info.child == []const u8 or child == .int or child == .float) {
            return;
        }
        if (child == .@"enum") {
            const info_enum = @typeInfo(info.child).@"enum";
            if (!info_enum.is_exhaustive) {
                @compileError("Field '" ++ field.name ++ "' in struct '" ++ @typeName(@"struct") ++ "' of type '" ++ @typeName(field.type) ++ "' must have an exhaustive Enum type.");
            }
            if (info_enum.fields.len < 2) {
                const err = std.fmt.comptimePrint("Field '" ++ field.name ++ "' in struct '" ++ @typeName(@"struct") ++ "' of type '" ++ @typeName(field.type) ++ "' must have at least 2 possible enum values. Has {}", .{info_enum.fields.len});
                @compileError(err);
            }
            return;
        }
    }

    @compileError(
        "Field '" ++ field.name ++
            "' in struct '" ++ @typeName(@"struct") ++
            "' of type '" ++ @typeName(field.type) ++
            "' is unsupported. Must be an integer or []const u8",
    );
}

fn defaultValue(comptime field: std.builtin.Type.StructField) ?field.type {
    return if (field.default_value_ptr) |default_opaque|
        @as(*const field.type, @ptrCast(@alignCast(default_opaque))).*
    else
        null;
}

fn logFatal(comptime format: []const u8, args: anytype) noreturn {
    log.err(format, args);
    std.process.exit(1);
}
