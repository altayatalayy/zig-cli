//! The spec-driven parser: `parse` reads a command's shape from plain Zig
//! types and fills it from argv. A struct is one command (fields are flags, a
//! `positionals` decl names the positional fields, a `union(enum)` field is the
//! subcommand); a tagged union is a command group whose variants are
//! subcommand words. The comptime reflection that drives this — and that the
//! help generator reuses — lives here too.

const std = @import("std");
const parser = @import("parser.zig");

const Parser = parser.Parser;
const Flag = parser.Flag;
const ParseError = parser.ParseError;

/// Parses the parser's remaining arguments against a command spec `T`: a
/// struct for one command or a tagged union for a command group. On error,
/// `p.offending` names the argument (or absent flag/field) at fault.
///
/// Spec rules, checked at compile time:
/// - Struct fields are flags unless a `pub const positionals` decl lists
///   them (parsed in the decl's order) or their type is a `union(enum)`
///   (the subcommand; at most one such field).
/// - Fields without a default value are required; absent ones yield
///   `MissingFlag`, `MissingArgument`, or `MissingCommand`.
/// - `bool` flags are switches; `[]const u8`, integer, and enum fields
///   (optionally `?`-wrapped) take one value. A final positional field of
///   type `[]const [:0]const u8` is variadic: it captures the rest of argv
///   verbatim, so flags must precede it.
/// - Union variant names match dashed words (`from_ir` <- `from-ir`) and
///   their payloads parse recursively; `void` payloads accept no further
///   arguments. Arguments after the subcommand word belong to the
///   subcommand, so parent flags must come before it.
pub fn parse(comptime T: type, p: *Parser) ParseError!T {
    return switch (@typeInfo(T)) {
        .@"struct" => parseStruct(T, p),
        .@"union" => parseUnion(T, p),
        else => @compileError("cli: parse expects a struct or union(enum) spec, got " ++ @typeName(T)),
    };
}

/// Maps a subcommand word to an enum tag; `-` matches `_` so `from-ir`
/// resolves to `.from_ir`.
pub fn command(comptime E: type, word: []const u8) error{UnknownCommand}!E {
    return parser.parseEnum(E, word) orelse error.UnknownCommand;
}

/// Incremental flag parsing over an options struct `T` for applications
/// that drive the `Parser` loop themselves, e.g. to layer extra flags by
/// handling `error.UnknownFlag`. Every field needs a default value; use
/// `parse` for required flags, positionals, and subcommands.
pub fn Flags(comptime T: type) type {
    return struct {
        values: T = .{},
        seen: Seen(T) = .empty,

        const Self = @This();

        pub fn set(self: *Self, p: *Parser, flag: Flag) ParseError!void {
            return setFlag(T, &self.values, &self.seen, p, flag);
        }
    };
}

/// Stores `value` into an optional slot, rejecting repeated flags.
pub fn setOnce(comptime T: type, slot: *?T, value: T) error{DuplicateFlag}!void {
    if (slot.* != null) return error.DuplicateFlag;
    slot.* = value;
}

/// Splits a comma-separated flag value. The returned slice is owned by the
/// caller; the elements borrow `text`.
pub fn splitList(alloc: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]const []const u8 {
    var items: std.ArrayList([]const u8) = .empty;
    errdefer items.deinit(alloc);
    var it = std.mem.tokenizeScalar(u8, text, ',');
    while (it.next()) |item| try items.append(alloc, item);
    return items.toOwnedSlice(alloc);
}

// --- spec-driven parsing internals ---

fn parseStruct(comptime T: type, p: *Parser) ParseError!T {
    comptime validateStruct(T);
    var result: T = undefined;
    var seen: Seen(T) = .empty;

    while (p.next()) |arg| switch (arg) {
        .flag => |flag| try setFlag(T, &result, &seen, p, flag),
        .positional => |word| try setPositional(T, &result, &seen, p, word),
    };

    const fields = @typeInfo(T).@"struct";
    inline for (fields.field_names, fields.field_types, fields.field_attrs, 0..) |name, field_type, attrs, i| {
        if (!seen.isSet(i)) {
            if (comptime attrs.defaultValue(field_type)) |default| {
                @field(result, name) = default;
            } else switch (comptime fieldKind(T, name)) {
                .flag => return p.fail(error.MissingFlag, comptime flagName(name)),
                .positional => return p.fail(error.MissingArgument, name),
                .subcommand => return p.fail(error.MissingCommand, name),
            }
        }
    }
    return result;
}

fn parseUnion(comptime U: type, p: *Parser) ParseError!U {
    const arg = p.next() orelse return p.fail(error.MissingCommand, "");
    return switch (arg) {
        .positional => |word| dispatch(U, p, word),
        .flag => |flag| p.fail(error.UnknownFlag, flag.name),
    };
}

fn dispatch(comptime U: type, p: *Parser, word: []const u8) ParseError!U {
    comptime validateUnion(U);
    const fields = @typeInfo(U).@"union";
    inline for (fields.field_names, fields.field_types) |name, field_type| {
        if (parser.eqlDashed(name, word)) {
            return @unionInit(U, name, try parsePayload(field_type, p));
        }
    }
    return p.fail(error.UnknownCommand, word);
}

fn parsePayload(comptime T: type, p: *Parser) ParseError!T {
    if (T == void) return p.expectDone();
    return parse(T, p);
}

fn setFlag(comptime T: type, values: *T, seen: *Seen(T), p: *Parser, flag: Flag) ParseError!void {
    const fields = @typeInfo(T).@"struct";
    inline for (fields.field_names, fields.field_types, 0..) |name, field_type, i| {
        if (comptime fieldKind(T, name) == .flag) {
            if (matchesFlag(T, name, flag.name)) {
                if (seen.isSet(i)) return p.fail(error.DuplicateFlag, flag.name);
                seen.set(i);
                @field(values, name) = try parseFlagValue(field_type, p, flag);
                return;
            }
        }
    }
    return p.fail(error.UnknownFlag, flag.name);
}

fn setPositional(comptime T: type, values: *T, seen: *Seen(T), p: *Parser, word: []const u8) ParseError!void {
    inline for (comptime positionalNames(T)) |name| {
        const i = comptime std.meta.fieldIndex(T, name).?;
        if (!seen.isSet(i)) {
            seen.set(i);
            const F = @FieldType(T, name);
            if (comptime isVariadic(F)) {
                @field(values, name) = p.args[p.index - 1 ..];
                p.index = p.args.len;
            } else {
                @field(values, name) = try parser.parseValue(F, p, word);
            }
            return;
        }
    }
    const fields = @typeInfo(T).@"struct";
    inline for (fields.field_names, fields.field_types, 0..) |name, field_type, i| {
        if (comptime fieldKind(T, name) == .subcommand) {
            seen.set(i);
            @field(values, name) = try dispatchInto(field_type, p, word);
            return;
        }
    }
    return p.fail(error.UnexpectedArgument, word);
}

fn dispatchInto(comptime T: type, p: *Parser, word: []const u8) ParseError!T {
    return switch (@typeInfo(T)) {
        .optional => |opt| try dispatch(opt.child, p, word),
        .@"union" => dispatch(T, p, word),
        else => unreachable,
    };
}

fn parseFlagValue(comptime T: type, p: *Parser, flag: Flag) ParseError!T {
    if (T == bool) {
        if (flag.value != null) return p.fail(error.InvalidValue, flag.name);
        return true;
    }
    return parser.parseValue(T, p, try p.value(flag));
}

// --- comptime spec reflection ---

pub const FieldKind = enum { flag, positional, subcommand };

pub fn fieldKind(comptime T: type, comptime field_name: []const u8) FieldKind {
    comptime {
        for (positionalNames(T)) |name| {
            if (std.mem.eql(u8, name, field_name)) return .positional;
        }
        if (isCommandType(@FieldType(T, field_name))) return .subcommand;
        return .flag;
    }
}

pub fn isCommandType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"union" => true,
        .optional => |opt| @typeInfo(opt.child) == .@"union",
        else => false,
    };
}

pub fn isVariadic(comptime T: type) bool {
    return T == []const [:0]const u8;
}

pub fn positionalNames(comptime T: type) []const []const u8 {
    comptime {
        if (!@hasDecl(T, "positionals")) return &.{};
        var names: [T.positionals.len][]const u8 = undefined;
        for (T.positionals, 0..) |name, i| names[i] = name;
        const out = names;
        return &out;
    }
}

pub const Shorthand = struct { letter: u8, field: []const u8 };

pub fn shorthandsOf(comptime T: type) []const Shorthand {
    comptime {
        if (!@hasDecl(T, "shorthands")) return &.{};
        const names = @typeInfo(@TypeOf(T.shorthands)).@"struct".field_names;
        var out: [names.len]Shorthand = undefined;
        for (names, 0..) |name, i| {
            if (name.len != 1) {
                @compileError("cli: shorthand '" ++ name ++ "' in " ++ @typeName(T) ++ " must be a single letter");
            }
            out[i] = .{ .letter = name[0], .field = @field(T.shorthands, name) };
        }
        const final = out;
        return &final;
    }
}

fn matchesFlag(comptime T: type, comptime field_name: []const u8, flag_name: []const u8) bool {
    if (std.mem.startsWith(u8, flag_name, "--")) return parser.eqlDashed(field_name, flag_name[2..]);
    if (flag_name.len != 2) return false;
    inline for (comptime shorthandsOf(T)) |sh| {
        if (comptime std.mem.eql(u8, sh.field, field_name)) {
            if (flag_name[1] == sh.letter) return true;
        }
    }
    return false;
}

/// The long-flag spelling of a struct field: `output_dir` -> `--output-dir`.
pub fn flagName(comptime field_name: []const u8) []const u8 {
    comptime {
        var dashed: [field_name.len]u8 = undefined;
        for (field_name, 0..) |c, i| dashed[i] = if (c == '_') '-' else c;
        const full = "--" ++ dashed;
        return full;
    }
}

fn Seen(comptime T: type) type {
    return std.StaticBitSet(@typeInfo(T).@"struct".field_names.len);
}

pub fn validateStruct(comptime T: type) void {
    comptime {
        const fields = @typeInfo(T).@"struct";
        const pos = positionalNames(T);
        for (pos, 0..) |name, order| {
            const i = std.meta.fieldIndex(T, name) orelse
                @compileError("cli: positionals decl in " ++ @typeName(T) ++ " names unknown field '" ++ name ++ "'");
            const F = fields.field_types[i];
            if (isCommandType(F)) @compileError("cli: positional field '" ++ name ++ "' cannot be a command union");
            if (F == bool) @compileError("cli: positional field '" ++ name ++ "' cannot be bool");
            if (isVariadic(F) and order != pos.len - 1) {
                @compileError("cli: variadic positional '" ++ name ++ "' must be last in " ++ @typeName(T));
            }
        }
        var commands = 0;
        for (fields.field_names) |name| {
            if (fieldKind(T, name) == .subcommand) commands += 1;
        }
        if (commands > 1) @compileError("cli: " ++ @typeName(T) ++ " declares more than one command union field");
        for (shorthandsOf(T)) |sh| {
            _ = std.meta.fieldIndex(T, sh.field) orelse
                @compileError("cli: shorthand in " ++ @typeName(T) ++ " targets unknown field '" ++ sh.field ++ "'");
            if (fieldKind(T, sh.field) != .flag) {
                @compileError("cli: shorthand target '" ++ sh.field ++ "' in " ++ @typeName(T) ++ " is not a flag");
            }
        }
    }
}

pub fn validateUnion(comptime U: type) void {
    comptime {
        if (@typeInfo(U).@"union".tag_type == null) {
            @compileError("cli: command union " ++ @typeName(U) ++ " must be a tagged union(enum)");
        }
    }
}

// --- tests ---

const testing = std.testing;

test "command maps words to enum tags" {
    const Verb = enum { plan, from_ir };
    try testing.expectEqual(Verb.plan, try command(Verb, "plan"));
    try testing.expectEqual(Verb.from_ir, try command(Verb, "from-ir"));
    try testing.expectError(error.UnknownCommand, command(Verb, "bogus"));
}

const TestOpts = struct {
    name: ?[]const u8 = null,
    output_dir: []const u8 = ".",
    jobs: u32 = 1,
    mode: enum { strict, best_effort } = .strict,
    verbose: bool = false,

    pub const shorthands = .{ .v = "verbose", .j = "jobs" };
};

test "Flags fills an options struct from long flags" {
    var p = Parser.init(&.{
        "--name=zig", "--output-dir", "out", "--jobs=4", "--mode=best-effort", "--verbose",
    });
    var flags: Flags(TestOpts) = .{};
    while (p.next()) |arg| try flags.set(&p, arg.flag);

    try testing.expectEqualStrings("zig", flags.values.name.?);
    try testing.expectEqualStrings("out", flags.values.output_dir);
    try testing.expectEqual(@as(u32, 4), flags.values.jobs);
    try testing.expectEqual(.best_effort, flags.values.mode);
    try testing.expect(flags.values.verbose);
}

test "Flags keeps defaults for absent flags" {
    var p = Parser.init(&.{"--jobs=2"});
    var flags: Flags(TestOpts) = .{};
    while (p.next()) |arg| try flags.set(&p, arg.flag);

    try testing.expect(flags.values.name == null);
    try testing.expectEqualStrings(".", flags.values.output_dir);
    try testing.expectEqual(.strict, flags.values.mode);
    try testing.expect(!flags.values.verbose);
}

test "Flags rejects unknown flags, repeats, and valued switches" {
    var flags: Flags(TestOpts) = .{};

    var p = Parser.init(&.{"--bogus"});
    try testing.expectError(error.UnknownFlag, flags.set(&p, p.next().?.flag));
    try testing.expectEqualStrings("--bogus", p.offending);

    var q = Parser.init(&.{ "--jobs=1", "--jobs=2" });
    try flags.set(&q, q.next().?.flag);
    try testing.expectError(error.DuplicateFlag, flags.set(&q, q.next().?.flag));

    var r = Parser.init(&.{"--verbose=yes"});
    try testing.expectError(error.InvalidValue, flags.set(&r, r.next().?.flag));
}

test "shorthands alias their long flags" {
    var p = Parser.init(&.{ "-v", "-j", "3" });
    var flags: Flags(TestOpts) = .{};
    while (p.next()) |arg| try flags.set(&p, arg.flag);
    try testing.expect(flags.values.verbose);
    try testing.expectEqual(@as(u32, 3), flags.values.jobs);

    var q = Parser.init(&.{ "-v", "--verbose" });
    var dup: Flags(TestOpts) = .{};
    try dup.set(&q, q.next().?.flag);
    try testing.expectError(error.DuplicateFlag, dup.set(&q, q.next().?.flag));

    var r = Parser.init(&.{"-x"});
    var unknown: Flags(TestOpts) = .{};
    try testing.expectError(error.UnknownFlag, unknown.set(&r, r.next().?.flag));
}

test "parse requires flags without defaults" {
    const Opts = struct {
        out: []const u8,
        jobs: u32 = 1,
    };

    var p = Parser.init(&.{ "--out=dist", "--jobs", "4" });
    const opts = try parse(Opts, &p);
    try testing.expectEqualStrings("dist", opts.out);
    try testing.expectEqual(@as(u32, 4), opts.jobs);

    var q = Parser.init(&.{"--jobs=2"});
    try testing.expectError(error.MissingFlag, parse(Opts, &q));
    try testing.expectEqualStrings("--out", q.offending);
}

test "parse fills positionals in decl order" {
    const Cp = struct {
        force: bool = false,
        src: []const u8,
        dst: []const u8,
        retries: ?u8 = null,

        pub const positionals = .{ "src", "dst", "retries" };
    };

    var p = Parser.init(&.{ "a.txt", "--force", "b.txt" });
    const opts = try parse(Cp, &p);
    try testing.expectEqualStrings("a.txt", opts.src);
    try testing.expectEqualStrings("b.txt", opts.dst);
    try testing.expect(opts.retries == null);
    try testing.expect(opts.force);

    var q = Parser.init(&.{"a.txt"});
    try testing.expectError(error.MissingArgument, parse(Cp, &q));
    try testing.expectEqualStrings("dst", q.offending);

    var r = Parser.init(&.{ "a", "b", "9", "extra" });
    try testing.expectError(error.UnexpectedArgument, parse(Cp, &r));
    try testing.expectEqualStrings("extra", r.offending);
}

test "parse captures variadic positionals" {
    const Sum = struct {
        values: []const [:0]const u8,

        pub const positionals = .{"values"};
    };

    var p = Parser.init(&.{ "1", "-2", "3" });
    const opts = try parse(Sum, &p);
    try testing.expectEqual(@as(usize, 3), opts.values.len);
    try testing.expectEqualStrings("-2", opts.values[1]);

    var q = Parser.init(&.{});
    try testing.expectError(error.MissingArgument, parse(Sum, &q));
    try testing.expectEqualStrings("values", q.offending);
}

const TestCli = struct {
    verbose: bool = false,
    command: union(enum) {
        greet: struct { name: ?[]const u8 = null },
        remote: union(enum) {
            add: struct {
                fetch: bool = false,
                name: []const u8,
                url: []const u8,

                pub const positionals = .{ "name", "url" };
            },
            list: void,
        },
    },

    pub const shorthands = .{ .v = "verbose" };
};

test "parse dispatches nested commands" {
    var p = Parser.init(&.{ "-v", "remote", "add", "origin", "https://x", "--fetch" });
    const cli = try parse(TestCli, &p);
    try testing.expect(cli.verbose);
    const add = cli.command.remote.add;
    try testing.expectEqualStrings("origin", add.name);
    try testing.expectEqualStrings("https://x", add.url);
    try testing.expect(add.fetch);

    var q = Parser.init(&.{ "remote", "list" });
    const list = try parse(TestCli, &q);
    try testing.expect(list.command.remote == .list);
}

test "parse reports missing, unknown, and overlong commands" {
    var p = Parser.init(&.{"--verbose"});
    try testing.expectError(error.MissingCommand, parse(TestCli, &p));
    try testing.expectEqualStrings("command", p.offending);

    var q = Parser.init(&.{"bogus"});
    try testing.expectError(error.UnknownCommand, parse(TestCli, &q));
    try testing.expectEqualStrings("bogus", q.offending);

    var r = Parser.init(&.{"remote"});
    try testing.expectError(error.MissingCommand, parse(TestCli, &r));

    var s = Parser.init(&.{ "remote", "list", "extra" });
    try testing.expectError(error.UnexpectedArgument, parse(TestCli, &s));
    try testing.expectEqualStrings("extra", s.offending);
}

test "parse rejects parent flags after the subcommand" {
    var p = Parser.init(&.{ "greet", "-v" });
    try testing.expectError(error.UnknownFlag, parse(TestCli, &p));
    try testing.expectEqualStrings("-v", p.offending);
}

test "parse with optional subcommand stays null" {
    const Spec = struct {
        version: bool = false,
        command: ?union(enum) { run: void } = null,
    };

    var p = Parser.init(&.{"--version"});
    const bare = try parse(Spec, &p);
    try testing.expect(bare.version);
    try testing.expect(bare.command == null);

    var q = Parser.init(&.{"run"});
    const run = try parse(Spec, &q);
    try testing.expect(run.command.? == .run);
}

test "parse accepts a top-level union and dashed words" {
    const Tool = union(enum) {
        version: void,
        from_ir: struct {
            path: []const u8,

            pub const positionals = .{"path"};
        },
    };

    var p = Parser.init(&.{ "from-ir", "ir.json" });
    const cli = try parse(Tool, &p);
    try testing.expectEqualStrings("ir.json", cli.from_ir.path);

    var q = Parser.init(&.{});
    try testing.expectError(error.MissingCommand, parse(Tool, &q));

    var r = Parser.init(&.{"--help"});
    try testing.expectError(error.UnknownFlag, parse(Tool, &r));
}

test "setOnce rejects duplicates" {
    var slot: ?[]const u8 = null;
    try setOnce([]const u8, &slot, "a");
    try testing.expectError(error.DuplicateFlag, setOnce([]const u8, &slot, "b"));
    try testing.expectEqualStrings("a", slot.?);
}

test "splitList tokenizes commas" {
    const alloc = testing.allocator;
    const items = try splitList(alloc, "neovim,tmux,,git");
    defer alloc.free(items);

    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqualStrings("neovim", items[0]);
    try testing.expectEqualStrings("tmux", items[1]);
    try testing.expectEqualStrings("git", items[2]);
}
