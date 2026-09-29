//! Comptime-driven command-line parsing in the spirit of clap (Rust), cobra
//! (Go), and click (Python), without their builders or allocation: the
//! command shape is plain Zig types and `parse` derives the parser from them.
//!
//! - A struct describes one command: each field is a flag (`output_dir`
//!   spells `--output-dir`), fields named by a `pub const positionals` decl
//!   are positional arguments, and a field of `union(enum)` type holds the
//!   subcommand. Fields without default values are required.
//! - A tagged union describes a command group: each variant name is a
//!   subcommand word and its payload (struct, nested union, or `void`) is
//!   parsed recursively, so command trees nest to any depth.
//! - A `pub const shorthands` decl (e.g. `.{ .v = "verbose" }`) declares
//!   single-letter aliases for flags.
//!
//! Help text is generated from the same specs: `help(T, prog)` renders a full
//! help screen as a comptime string, drawing one-line summaries from an
//! optional `pub const descriptions` decl, a blurb from `pub const about`, and
//! a trailing note from `pub const footer`. `subcommandHelp` covers
//! command-level help.
//!
//! The library is split across a few files; this root re-exports the public
//! surface:
//! - `parser.zig` — the low-level `Parser` iterator and value helpers.
//! - `spec.zig`   — `parse`, `Flags`, `command`, and the comptime reflection.
//! - `help.zig`   — `help`, `usage`, and `subcommandHelp`.

const parser = @import("parser.zig");
const spec = @import("spec.zig");
const help_mod = @import("help.zig");

// Low-level argument tokenizer.
pub const ParseError = parser.ParseError;
pub const Flag = parser.Flag;
pub const Arg = parser.Arg;
pub const Parser = parser.Parser;

// Spec-driven parsing.
pub const parse = spec.parse;
pub const command = spec.command;
pub const Flags = spec.Flags;
pub const setOnce = spec.setOnce;
pub const splitList = spec.splitList;

// Comptime help generation.
pub const help = help_mod.help;
pub const usage = help_mod.usage;
pub const subcommandHelp = help_mod.subcommandHelp;
pub const helpRequested = help_mod.helpRequested;
pub const helpFor = help_mod.helpFor;

test {
    _ = parser;
    _ = spec;
    _ = help_mod;
}
