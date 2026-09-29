# zig-cli

Comptime-driven command-line parsing for Zig 0.16, in the spirit of clap
(Rust), cobra (Go), and click (Python) but without builders or allocation:
the command shape is plain Zig types and `cli.parse` derives the parser.

```zig
const Demo = struct {
    verbose: bool = false,        // optional flag: --verbose
    command: union(enum) {        // subcommands, nested to any depth
        greet: struct {
            name: ?[]const u8 = null, // --name <who>
            times: u32 = 1,           // --times <n>
        },
        remote: union(enum) {
            add: struct {
                fetch: bool = false,
                name: []const u8,     // required positional
                url: []const u8,      // required positional

                pub const positionals = .{ "name", "url" };
            },
            list: void,               // leaf command with no arguments
        },
    },

    pub const shorthands = .{ .v = "verbose" }; // -v
};

var p = cli.Parser.init(args[1..]);
const demo = cli.parse(Demo, &p) catch |err| {
    std.log.err("{t} at '{s}'", .{ err, p.offending });
    ...
};
```

## Spec rules

- A **struct** is one command. Each field is a long flag (`output_dir`
  spells `--output-dir`) unless a `pub const positionals` decl lists it or
  its type is a `union(enum)`.
- A **tagged union** is a command group: variant names are subcommand words
  (`from_ir` matches `from-ir`), payloads (struct, nested union, or `void`)
  parse recursively. Arguments after the subcommand word belong to the
  subcommand, so parent flags come before it.
- Fields **without default values are required**; absent ones yield
  `error.MissingFlag`, `error.MissingArgument`, or `error.MissingCommand`.
- Flag types: `bool` is a switch; `[]const u8`, integers, and enums
  (optionally `?`-wrapped) take a value (`--jobs 4` or `--jobs=4`).
- Positionals fill in the decl's order and may interleave with flags. A
  final field of type `[]const [:0]const u8` is variadic and captures the
  rest of argv verbatim.
- `pub const shorthands = .{ .v = "verbose" }` declares single-letter
  aliases.
- `--` makes everything after it positional; a lone `-` and negative
  numbers (`-5`) are positional.

On error, `Parser.offending` names the argument (or missing flag/field) at
fault for precise diagnostics.

## Help generation

Help screens are derived from the same spec types — no hand-maintained usage
strings. Add optional decls and call `cli.help`:

```zig
const Cli = union(enum) {
    greet: struct {
        name: ?[]const u8 = null,
        pub const about = "Greet someone by name.";
        pub const descriptions = .{ .name = "who to greet" };
    },
    version: void,

    pub const about = "demo — a tiny tour of the cli library";
    pub const footer = "Run 'demo <command> --help' for command details.";
    pub const descriptions = .{ .greet = "say hello", .version = "print the version" };
};

// `-h`/`--help` handling: `demo --help` shows the top-level screen and
// `demo <command> --help` shows command-level help. Returns null when no help
// flag is present, so you fall through to parse:
if (cli.helpFor(Cli, "demo", args[1..])) |text| {
    try w.writeAll(text);
    return;
}

// Or reach for the pieces directly:
try w.writeAll(cli.help(Cli, "demo"));                  // full top-level screen
try w.writeAll(cli.usage(Cli, "demo"));                 // one-line synopsis (parse errors)
try w.writeAll(cli.subcommandHelp(Cli, "demo", .greet)); // command-level help by tag
```

- `pub const about` — a blurb shown at the top of the screen.
- `pub const descriptions = .{ .field = "..." }` — one-line summaries for
  flags, positionals, and subcommand variants (mirrors `shorthands`). A typo'd
  key is a compile error.
- `pub const footer` — a trailing note.

The output has the usual `usage:` line plus `Arguments`, `Options`, and
`Commands` sections; required flags are marked, and value placeholders reflect
the field type (`<n>` for ints, `<a|b|c>` for enums). Everything is a comptime
`[]const u8`, so there is zero runtime cost.

## Layout

The library is split into focused files, re-exported from `src/root.zig`:

- `parser.zig` — the low-level `Parser` iterator and value helpers.
- `spec.zig` — `parse`, `Flags`, `command`, `setOnce`, `splitList`, and the
  comptime reflection that drives them.
- `help.zig` — `help`, `usage`, and `subcommandHelp`.

The low-level pieces remain available for custom argument handling.

Import the module as `cli`; see `examples/demo.zig` (`zig build example --
greet --name zig`, or `zig build example -- --help`). Run tests with
`zig build test`.
