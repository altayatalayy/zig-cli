//! The low-level argument tokenizer: `Parser` walks argv splitting flags from
//! positionals, and the value helpers turn a flag's argument into a string,
//! integer, or enum. The spec-driven `parse` (see `spec.zig`) is built on top
//! of this; applications that need bespoke handling can drive `Parser` directly.

const std = @import("std");

pub const ParseError = error{
    /// A subcommand word matched no variant of the command union.
    UnknownCommand,
    /// A required command union field got no subcommand word.
    MissingCommand,
    UnknownFlag,
    /// A required flag (struct field without default) was absent.
    MissingFlag,
    /// A flag that takes a value got none.
    MissingValue,
    InvalidValue,
    DuplicateFlag,
    /// A required positional field was absent.
    MissingArgument,
    UnexpectedArgument,
};

pub const Flag = struct {
    /// Includes the leading dashes, e.g. "--output-dir".
    name: []const u8,
    /// Present only for the `--name=value` form.
    value: ?[]const u8,

    pub fn is(self: Flag, name: []const u8) bool {
        return std.mem.eql(u8, self.name, name);
    }
};

pub const Arg = union(enum) {
    flag: Flag,
    positional: []const u8,
};

pub const Parser = struct {
    args: []const [:0]const u8,
    index: usize = 0,
    /// After `--`, every remaining argument is positional.
    literal: bool = false,
    /// Set alongside any returned error: the argument or flag name that
    /// caused it, so callers can log a precise message.
    offending: []const u8 = "",

    pub fn init(args: []const [:0]const u8) Parser {
        return .{ .args = args };
    }

    /// Returns the next argument, splitting `--name=value` flags. A bare
    /// `--` switches to literal mode; a lone `-` and negative numbers
    /// (`-5`) are positional.
    pub fn next(self: *Parser) ?Arg {
        while (self.index < self.args.len) {
            const arg = self.args[self.index];
            self.index += 1;
            if (self.literal) return .{ .positional = arg };
            if (std.mem.eql(u8, arg, "--")) {
                self.literal = true;
                continue;
            }
            if (arg.len > 1 and arg[0] == '-' and !std.ascii.isDigit(arg[1])) {
                if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
                    return .{ .flag = .{ .name = arg[0..eq], .value = arg[eq + 1 ..] } };
                }
                return .{ .flag = .{ .name = arg, .value = null } };
            }
            return .{ .positional = arg };
        }
        return null;
    }

    /// The value of `flag`: inline (`--name=value`) or the next argument.
    /// The next argument is rejected when it looks like another long flag.
    pub fn value(self: *Parser, flag: Flag) ParseError![]const u8 {
        if (flag.value) |v| return v;
        if (self.index >= self.args.len or std.mem.startsWith(u8, self.args[self.index], "--")) {
            return self.fail(error.MissingValue, flag.name);
        }
        const v = self.args[self.index];
        self.index += 1;
        return v;
    }

    /// Parses the flag value as an enum tag; `-` in the value matches `_`
    /// in the tag name (`--mode=best-effort` -> `.best_effort`).
    pub fn enumValue(self: *Parser, comptime E: type, flag: Flag) ParseError!E {
        return parseValue(E, self, try self.value(flag));
    }

    pub fn intValue(self: *Parser, comptime T: type, flag: Flag) ParseError!T {
        return parseValue(T, self, try self.value(flag));
    }

    /// Errors unless every argument has been consumed.
    pub fn expectDone(self: *Parser) ParseError!void {
        if (self.index < self.args.len) {
            return self.fail(error.UnexpectedArgument, self.args[self.index]);
        }
    }

    pub fn fail(self: *Parser, err: ParseError, offending: []const u8) ParseError {
        self.offending = offending;
        return err;
    }
};

/// Parses `text` into `T`: `[]const u8` passes through, integers and enums are
/// parsed (`-` matches `_` for enum tags), and `?`-wrapped types unwrap. On a
/// bad value records `text` as the offender and returns `error.InvalidValue`.
pub fn parseValue(comptime T: type, p: *Parser, text: []const u8) ParseError!T {
    if (T == []const u8) return text;
    return switch (@typeInfo(T)) {
        .optional => |opt| try parseValue(opt.child, p, text),
        .int => std.fmt.parseInt(T, text, 10) catch p.fail(error.InvalidValue, text),
        .@"enum" => parseEnum(T, text) orelse p.fail(error.InvalidValue, text),
        else => @compileError("cli: unsupported argument type " ++ @typeName(T)),
    };
}

/// Maps a dashed word to an enum tag; `-` matches `_` so `from-ir` resolves to
/// `.from_ir`. Returns null when no tag matches.
pub fn parseEnum(comptime E: type, text: []const u8) ?E {
    const info = @typeInfo(E).@"enum";
    inline for (info.field_names, info.field_values) |name, value| {
        if (eqlDashed(name, text)) return @fromBackingInt(@intCast(value));
    }
    return null;
}

/// Compares an identifier `tag_name` against argv `text`, treating `_` in the
/// identifier as interchangeable with `-` in the text.
pub fn eqlDashed(tag_name: []const u8, text: []const u8) bool {
    if (tag_name.len != text.len) return false;
    for (tag_name, text) |t, c| {
        if (t != if (c == '-') '_' else c) return false;
    }
    return true;
}

// --- tests ---

const testing = std.testing;

test "next yields flags and positionals" {
    var p = Parser.init(&.{ "plan", "--installer=0.2.0", "--add", "zig", "-v" });

    try testing.expectEqualStrings("plan", p.next().?.positional);

    const installer = p.next().?.flag;
    try testing.expect(installer.is("--installer"));
    try testing.expectEqualStrings("0.2.0", installer.value.?);

    const add = p.next().?.flag;
    try testing.expect(add.is("--add"));
    try testing.expect(add.value == null);
    try testing.expectEqualStrings("zig", try p.value(add));

    try testing.expect(p.next().?.flag.is("-v"));
    try testing.expect(p.next() == null);
}

test "double dash makes the rest positional" {
    var p = Parser.init(&.{ "--", "--not-a-flag", "-" });
    try testing.expectEqualStrings("--not-a-flag", p.next().?.positional);
    try testing.expectEqualStrings("-", p.next().?.positional);
    try testing.expect(p.next() == null);
}

test "lone dash and negative numbers are positional" {
    var p = Parser.init(&.{ "-", "-5", "-12" });
    try testing.expectEqualStrings("-", p.next().?.positional);
    try testing.expectEqualStrings("-5", p.next().?.positional);
    try testing.expectEqualStrings("-12", p.next().?.positional);
}

test "value rejects a missing or flag-like successor" {
    var p = Parser.init(&.{ "--tool", "--other" });
    const tool = p.next().?.flag;
    try testing.expectError(error.MissingValue, p.value(tool));
    try testing.expectEqualStrings("--tool", p.offending);

    var q = Parser.init(&.{"--tool"});
    const dangling = q.next().?.flag;
    try testing.expectError(error.MissingValue, q.value(dangling));
}

test "enumValue matches dashed spellings" {
    const Mode = enum { strict, best_effort };

    var p = Parser.init(&.{ "--mode=best-effort", "--mode", "strict", "--mode=bogus" });
    try testing.expectEqual(Mode.best_effort, try p.enumValue(Mode, p.next().?.flag));
    try testing.expectEqual(Mode.strict, try p.enumValue(Mode, p.next().?.flag));
    try testing.expectError(error.InvalidValue, p.enumValue(Mode, p.next().?.flag));
    try testing.expectEqualStrings("bogus", p.offending);
}

test "intValue parses and rejects" {
    var p = Parser.init(&.{ "--port=8080", "--port=x" });
    try testing.expectEqual(@as(u16, 8080), try p.intValue(u16, p.next().?.flag));
    try testing.expectError(error.InvalidValue, p.intValue(u16, p.next().?.flag));
}

test "expectDone flags trailing arguments" {
    var p = Parser.init(&.{"extra"});
    try testing.expectError(error.UnexpectedArgument, p.expectDone());
    try testing.expectEqualStrings("extra", p.offending);

    _ = p.next();
    try p.expectDone();
}

test "eqlDashed treats underscores and dashes alike" {
    try testing.expect(eqlDashed("from_ir", "from-ir"));
    try testing.expect(eqlDashed("plan", "plan"));
    try testing.expect(!eqlDashed("plan", "plans"));
    try testing.expect(!eqlDashed("from_ir", "from_xr"));
}
