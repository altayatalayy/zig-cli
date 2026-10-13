//! Comptime help/usage generation, derived from the same command specs that
//! `parse` consumes. `help(T, prog)` renders a full help screen as a single
//! static `[]const u8` — no allocation, no runtime work — pulling one-line
//! summaries from an optional `pub const descriptions` decl (mirroring
//! `shorthands`/`positionals`), a long blurb from `pub const about`, and a
//! trailing note from `pub const footer`.
//!
//! The shape follows the conventions shared by clap (Rust), cobra (Go), and
//! commander (JS): an about line, a `usage:` line, then `Arguments`,
//! `Options`, and `Commands` sections. `subcommandHelp` renders the help for
//! one variant of a command union so `prog help <cmd>` / `prog <cmd> --help`
//! can show command-level detail.

const std = @import("std");
const spec = @import("spec.zig");
const parser = @import("parser.zig");

const FieldKind = spec.FieldKind;

/// Renders the full help screen for command spec `T` invoked as `prog`. `T` is
/// a struct (one command) or a tagged union (a command group). The result is a
/// comptime-known static string; the `comptime` delegation lets callers invoke
/// it from ordinary runtime code without a `comptime` keyword.
pub fn help(comptime T: type, comptime prog: []const u8) []const u8 {
    return comptime helpImpl(T, prog);
}

fn helpImpl(comptime T: type, comptime prog: []const u8) []const u8 {
    validateMeta(T);
    return switch (@typeInfo(T)) {
        .@"struct" => structHelp(T, prog),
        .@"union" => unionHelp(T, prog),
        else => @compileError("cli: help expects a struct or union(enum) spec, got " ++ @typeName(T)),
    };
}

/// Just the one-line `usage:` synopsis for `T` (no sections), handy for the
/// short message printed on a parse error.
pub fn usage(comptime T: type, comptime prog: []const u8) []const u8 {
    return comptime usageImpl(T, prog);
}

fn usageImpl(comptime T: type, comptime prog: []const u8) []const u8 {
    validateMeta(T);
    return switch (@typeInfo(T)) {
        .@"struct" => usageLine(T, prog),
        .@"union" => "usage: " ++ prog ++ " <command> [args]",
        else => @compileError("cli: usage expects a struct or union(enum) spec, got " ++ @typeName(T)),
    };
}

/// Renders help for one variant of command union `U`, selected at runtime by
/// `tag`. `prog` is extended by the variant's subcommand word, so
/// `subcommandHelp(Command, "git", .remote)` documents `git remote`. A `void`
/// variant yields a bare usage line plus its description, if any.
pub fn subcommandHelp(comptime U: type, comptime prog: []const u8, tag: std.meta.Tag(U)) []const u8 {
    comptime spec.validateUnion(U);
    switch (tag) {
        inline else => |t| {
            const name = @tagName(t);
            const Payload = @FieldType(U, name);
            const sub_prog = prog ++ " " ++ comptime dashed(name);
            if (Payload == void) {
                const note = comptime descOf(U, name);
                return comptime if (note.len > 0)
                    note ++ "\n\nusage: " ++ sub_prog ++ "\n"
                else
                    "usage: " ++ sub_prog ++ "\n";
            }
            return comptime help(Payload, sub_prog);
        },
    }
}

/// True when `args` carries a `-h`/`--help` request before any `--` terminator.
pub fn helpRequested(args: []const [:0]const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--")) return false;
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return true;
    }
    return false;
}

/// `-h`/`--help` dispatch for a top-level command spec `T` invoked as `prog`.
/// `T` may be a command union or a struct with global flags and a subcommand
/// union field. Pass argv[1..]. Returns the help screen to print — command-level
/// help when a known command word precedes the flag (`prog cmd --help`),
/// otherwise the top-level screen (`prog --help`) — or null when no help flag is
/// present, so callers fall through to `parse`.
pub fn helpFor(comptime T: type, comptime prog: []const u8, args: []const [:0]const u8) ?[]const u8 {
    if (!helpRequested(args)) return null;
    if (comptime dispatchUnion(T)) |U| {
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "--")) break;
            if (arg.len > 0 and arg[0] == '-') continue; // skip flags to reach the command word
            if (spec.command(std.meta.Tag(U), arg)) |tag| return subcommandHelp(U, prog, tag) else |_| {}
            break; // an unrecognized first word falls back to the top-level screen
        }
    }
    return help(T, prog);
}

/// The command union to dispatch subcommand help on: `T` itself when it is a
/// union, the (unwrapped) type of its subcommand field when `T` is a struct, or
/// null when `T` has no subcommands.
fn dispatchUnion(comptime T: type) ?type {
    comptime {
        switch (@typeInfo(T)) {
            .@"union" => return T,
            .@"struct" => {
                for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |name, field_type| {
                    if (spec.fieldKind(T, name) == .subcommand) return commandUnion(field_type);
                }
                return null;
            },
            else => return null,
        }
    }
}

// --- rendering ---

fn structHelp(comptime T: type, comptime prog: []const u8) []const u8 {
    comptime {
        const fields = @typeInfo(T).@"struct";
        const width = columnWidth(T);
        var out: []const u8 = "";

        if (declString(T, "about")) |a| out = out ++ a ++ "\n\n";
        out = out ++ usageLine(T, prog) ++ "\n";

        // Arguments
        var args_rows: []const u8 = "";
        for (spec.positionalNames(T)) |name| {
            args_rows = args_rows ++ row(posToken(T, name), descOf(T, name), width);
        }
        if (args_rows.len > 0) out = out ++ "\nArguments:\n" ++ args_rows;

        // Options
        var opt_rows: []const u8 = "";
        for (fields.field_names) |name| {
            if (spec.fieldKind(T, name) == .flag) {
                opt_rows = opt_rows ++ row(flagLabel(T, name), flagDesc(T, name), width);
            }
        }
        if (opt_rows.len > 0) out = out ++ "\nOptions:\n" ++ opt_rows;

        // Commands (a single subcommand union field, if present)
        for (fields.field_names, fields.field_types) |name, field_type| {
            if (spec.fieldKind(T, name) == .subcommand) {
                out = out ++ "\nCommands:\n" ++ commandRows(commandUnion(field_type), width);
            }
        }

        if (declString(T, "footer")) |fo| out = out ++ "\n" ++ fo ++ "\n";
        return out;
    }
}

fn unionHelp(comptime U: type, comptime prog: []const u8) []const u8 {
    comptime {
        spec.validateUnion(U);
        var out: []const u8 = "";
        if (declString(U, "about")) |a| out = out ++ a ++ "\n\n";
        out = out ++ "usage: " ++ prog ++ " <command> [args]\n";
        out = out ++ "\nCommands:\n" ++ commandRows(U, columnWidth(U));
        if (declString(U, "footer")) |fo| out = out ++ "\n" ++ fo ++ "\n";
        return out;
    }
}

fn commandRows(comptime U: type, comptime width: usize) []const u8 {
    comptime {
        var rows: []const u8 = "";
        for (@typeInfo(U).@"union".field_names) |name| {
            rows = rows ++ row(dashed(name), descOf(U, name), width);
        }
        return rows;
    }
}

fn usageLine(comptime T: type, comptime prog: []const u8) []const u8 {
    comptime {
        var s: []const u8 = "usage: " ++ prog;
        if (hasFlags(T)) s = s ++ " [options]";
        for (spec.positionalNames(T)) |name| s = s ++ " " ++ posToken(T, name);
        for (@typeInfo(T).@"struct".field_names) |name| {
            if (spec.fieldKind(T, name) == .subcommand) s = s ++ " <command>";
        }
        return s;
    }
}

// --- labels ---

fn flagLabel(comptime T: type, comptime field: []const u8) []const u8 {
    comptime {
        const long = spec.flagName(field);
        var base: []const u8 = undefined;
        if (shorthandFor(T, field)) |letter| {
            base = "-" ++ &[_]u8{letter} ++ ", " ++ long;
        } else {
            base = "    " ++ long; // align '--' under the short-flag column
        }
        return base ++ valuePlaceholder(@FieldType(T, field));
    }
}

fn flagDesc(comptime T: type, comptime name: []const u8) []const u8 {
    comptime {
        const d = descOf(T, name);
        const fields = @typeInfo(T).@"struct";
        const i = std.meta.fieldIndex(T, name).?;
        if (fields.field_attrs[i].defaultValue(fields.field_types[i]) == null) return if (d.len > 0) d ++ " (required)" else "(required)";
        return d;
    }
}

/// The synopsis token for a positional: `<name>`, `<name>...` (variadic), and
/// wrapped in `[...]` when optional (the field has a default).
fn posToken(comptime T: type, comptime name: []const u8) []const u8 {
    comptime {
        const F = @FieldType(T, name);
        var inner: []const u8 = "<" ++ dashed(name) ++ ">";
        if (spec.isVariadic(F)) inner = inner ++ "...";
        const i = std.meta.fieldIndex(T, name).?;
        const fields = @typeInfo(T).@"struct";
        const optional = fields.field_attrs[i].defaultValue(fields.field_types[i]) != null;
        return if (optional) "[" ++ inner ++ "]" else inner;
    }
}

fn valuePlaceholder(comptime F: type) []const u8 {
    comptime {
        return switch (@typeInfo(F)) {
            .optional => |opt| valuePlaceholder(opt.child),
            .bool => "",
            .int => " <n>",
            .@"enum" => " <" ++ enumChoices(F) ++ ">",
            else => " <value>",
        };
    }
}

fn enumChoices(comptime E: type) []const u8 {
    comptime {
        var s: []const u8 = "";
        for (@typeInfo(E).@"enum".field_names, 0..) |name, i| {
            s = s ++ (if (i == 0) "" else "|") ++ dashed(name);
        }
        return s;
    }
}

// --- layout helpers ---

fn row(comptime label: []const u8, comptime desc: []const u8, comptime width: usize) []const u8 {
    comptime {
        if (desc.len == 0) return "  " ++ label ++ "\n";
        return "  " ++ pad(label, width) ++ "  " ++ desc ++ "\n";
    }
}

fn pad(comptime s: []const u8, comptime width: usize) []const u8 {
    comptime {
        if (s.len >= width) return s;
        return s ++ spaces(width - s.len);
    }
}

fn spaces(comptime n: usize) []const u8 {
    comptime {
        var buf: [n]u8 = undefined;
        for (&buf) |*c| c.* = ' ';
        const out = buf;
        return &out;
    }
}

/// The width of the label column: the widest label across the Arguments,
/// Options, and Commands sections, capped so long labels don't push the
/// descriptions off the edge.
fn columnWidth(comptime T: type) usize {
    comptime {
        const cap = 26;
        var w: usize = 0;
        switch (@typeInfo(T)) {
            .@"union" => {
                for (@typeInfo(T).@"union".field_names) |name| w = @max(w, dashed(name).len);
            },
            .@"struct" => {
                for (spec.positionalNames(T)) |name| w = @max(w, posToken(T, name).len);
                for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |name, field_type| {
                    switch (spec.fieldKind(T, name)) {
                        .flag => w = @max(w, flagLabel(T, name).len),
                        .subcommand => for (@typeInfo(commandUnion(field_type)).@"union".field_names) |variant| {
                            w = @max(w, dashed(variant).len);
                        },
                        .positional => {},
                    }
                }
            },
            else => {},
        }
        return @min(w, cap);
    }
}

// --- spec metadata reflection ---

/// The dashed spelling of an identifier (`best_effort` -> `best-effort`),
/// without the leading `--`.
fn dashed(comptime name: []const u8) []const u8 {
    comptime {
        var buf: [name.len]u8 = undefined;
        for (name, 0..) |c, i| buf[i] = if (c == '_') '-' else c;
        const out = buf;
        return &out;
    }
}

/// The one-line description for `name` from `T`'s optional `descriptions` decl,
/// or "" when none is declared.
fn descOf(comptime T: type, comptime name: []const u8) []const u8 {
    comptime {
        if (!@hasDecl(T, "descriptions")) return "";
        if (!@hasField(@TypeOf(T.descriptions), name)) return "";
        return @field(T.descriptions, name);
    }
}

fn declString(comptime T: type, comptime decl: []const u8) ?[]const u8 {
    comptime {
        if (!@hasDecl(T, decl)) return null;
        return @field(T, decl);
    }
}

fn shorthandFor(comptime T: type, comptime field: []const u8) ?u8 {
    comptime {
        for (spec.shorthandsOf(T)) |sh| {
            if (std.mem.eql(u8, sh.field, field)) return sh.letter;
        }
        return null;
    }
}

fn hasFlags(comptime T: type) bool {
    comptime {
        for (@typeInfo(T).@"struct".field_names) |name| {
            if (spec.fieldKind(T, name) == .flag) return true;
        }
        return false;
    }
}

/// The union type behind a subcommand field, unwrapping an optional wrapper.
fn commandUnion(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .@"union" => T,
        .optional => |opt| opt.child,
        else => @compileError("cli: not a command union: " ++ @typeName(T)),
    };
}

/// Checks that `about`/`footer` are strings and that every key in a
/// `descriptions` decl names a real field (struct) or variant (union), so a
/// typo'd description key is a compile error rather than silently ignored.
fn validateMeta(comptime T: type) void {
    comptime {
        for ([_][]const u8{ "about", "footer" }) |decl| {
            if (@hasDecl(T, decl)) {
                const V = @TypeOf(@field(T, decl));
                if (V != []const u8 and !isStringLiteral(V)) {
                    @compileError("cli: " ++ decl ++ " in " ++ @typeName(T) ++ " must be a []const u8 string");
                }
            }
        }
        if (@hasDecl(T, "descriptions")) {
            const info = @typeInfo(@TypeOf(T.descriptions));
            if (info != .@"struct") {
                @compileError("cli: descriptions in " ++ @typeName(T) ++ " must be a struct literal");
            }
            for (info.@"struct".field_names) |name| {
                if (!nameExists(T, name)) {
                    @compileError("cli: descriptions in " ++ @typeName(T) ++ " names unknown field/command '" ++ name ++ "'");
                }
            }
        }
    }
}

fn nameExists(comptime T: type, comptime name: []const u8) bool {
    comptime {
        return switch (@typeInfo(T)) {
            .@"struct" => @hasField(T, name),
            .@"union" => @hasField(T, name),
            else => false,
        };
    }
}

/// True for the type of a string literal (`*const [N:0]u8`), which coerces to
/// `[]const u8` — `about`/`footer` are usually written as bare literals.
fn isStringLiteral(comptime V: type) bool {
    comptime {
        const info = @typeInfo(V);
        if (info != .pointer) return false;
        const child = @typeInfo(info.pointer.child);
        return info.pointer.size == .one and child == .array and child.array.child == u8;
    }
}

// --- tests ---

const testing = std.testing;

const Cp = struct {
    force: bool = false,
    jobs: u32 = 1,
    mode: enum { strict, best_effort } = .strict,
    src: []const u8,
    dst: []const u8,
    retries: ?u8 = null,

    pub const about = "copy files from src to dst";
    pub const positionals = .{ "src", "dst", "retries" };
    pub const shorthands = .{ .f = "force", .j = "jobs" };
    pub const descriptions = .{
        .force = "overwrite the destination",
        .jobs = "parallel copy jobs",
        .mode = "conflict handling",
        .src = "source path",
        .dst = "destination path",
    };
};

test "struct help renders about, usage, arguments, and options" {
    const text = comptime help(Cp, "cp");
    try testing.expect(std.mem.indexOf(u8, text, "copy files from src to dst") != null);
    try testing.expect(std.mem.indexOf(u8, text, "usage: cp [options] <src> <dst> [<retries>]") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Arguments:") != null);
    try testing.expect(std.mem.indexOf(u8, text, "<src>") != null);
    try testing.expect(std.mem.indexOf(u8, text, "source path") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Options:") != null);
    try testing.expect(std.mem.indexOf(u8, text, "-f, --force") != null);
    try testing.expect(std.mem.indexOf(u8, text, "-j, --jobs <n>") != null);
    try testing.expect(std.mem.indexOf(u8, text, "--mode <strict|best-effort>") != null);
    // required positional carries no brackets; subcommand-less spec has no Commands
    try testing.expect(std.mem.indexOf(u8, text, "Commands:") == null);
}

test "usage of a required string flag marks it required" {
    const Need = struct {
        out: []const u8,
        pub const descriptions = .{ .out = "output directory" };
    };
    const text = comptime help(Need, "tool");
    try testing.expect(std.mem.indexOf(u8, text, "output directory (required)") != null);
}

const Demo = union(enum) {
    greet: struct {
        name: ?[]const u8 = null,
        pub const descriptions = .{ .name = "who to greet" };
    },
    remote: union(enum) {
        add: struct {
            name: []const u8,
            url: []const u8,
            pub const positionals = .{ "name", "url" };
        },
        list: void,

        pub const about = "manage remotes";
        pub const descriptions = .{ .add = "add a remote", .list = "list remotes" };
    },
    version: void,

    pub const about = "demo — a sample tool";
    pub const footer = "Run 'demo <command> --help' for details.";
    pub const descriptions = .{
        .greet = "say hello",
        .remote = "manage remotes",
        .version = "print the version",
    };
};

test "union help lists commands with descriptions" {
    const text = comptime help(Demo, "demo");
    try testing.expect(std.mem.indexOf(u8, text, "demo — a sample tool") != null);
    try testing.expect(std.mem.indexOf(u8, text, "usage: demo <command> [args]") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Commands:") != null);
    try testing.expect(std.mem.indexOf(u8, text, "greet") != null);
    try testing.expect(std.mem.indexOf(u8, text, "say hello") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Run 'demo <command> --help' for details.") != null);
}

test "helpRequested honors -h, --help, and the -- terminator" {
    try testing.expect(helpRequested(&.{ "greet", "--help" }));
    try testing.expect(helpRequested(&.{"-h"}));
    try testing.expect(!helpRequested(&.{ "greet", "--name", "zig" }));
    try testing.expect(!helpRequested(&.{ "--", "--help" }));
}

test "helpFor dispatches top-level vs command help" {
    try testing.expect(helpFor(Demo, "demo", &.{ "greet", "--name", "zig" }) == null);

    const top = helpFor(Demo, "demo", &.{"--help"}).?;
    try testing.expect(std.mem.indexOf(u8, top, "usage: demo <command> [args]") != null);

    const cmd = helpFor(Demo, "demo", &.{ "greet", "--help" }).?;
    try testing.expect(std.mem.indexOf(u8, cmd, "usage: demo greet") != null);

    // an unknown leading word falls back to the top-level screen
    const fallback = helpFor(Demo, "demo", &.{ "bogus", "--help" }).?;
    try testing.expect(std.mem.indexOf(u8, fallback, "usage: demo <command> [args]") != null);
}

test "subcommandHelp renders the selected variant" {
    const greet = subcommandHelp(Demo, "demo", .greet);
    try testing.expect(std.mem.indexOf(u8, greet, "usage: demo greet") != null);
    try testing.expect(std.mem.indexOf(u8, greet, "who to greet") != null);

    const remote = subcommandHelp(Demo, "demo", .remote);
    try testing.expect(std.mem.indexOf(u8, remote, "usage: demo remote <command> [args]") != null);
    try testing.expect(std.mem.indexOf(u8, remote, "add a remote") != null);

    const version = subcommandHelp(Demo, "demo", .version);
    try testing.expect(std.mem.indexOf(u8, version, "print the version") != null);
    try testing.expect(std.mem.indexOf(u8, version, "usage: demo version") != null);
}

test "usage helper returns only the synopsis line" {
    try testing.expectEqualStrings("usage: cp [options] <src> <dst> [<retries>]", comptime usage(Cp, "cp"));
    try testing.expectEqualStrings("usage: demo <command> [args]", comptime usage(Demo, "demo"));
}
