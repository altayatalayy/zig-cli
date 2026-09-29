const std = @import("std");
const cli = @import("cli");

const Demo = struct {
    verbose: bool = false,
    command: Command,

    pub const about = "demo — a tiny tour of the cli library";
    pub const shorthands = .{ .v = "verbose" };
    pub const descriptions = .{ .verbose = "log the command being run" };
    pub const footer = "Run 'demo <command> --help' for command details.";

    const Command = union(enum) {
        greet: Greet,
        sum: Sum,
        remote: Remote,

        pub const descriptions = .{
            .greet = "say hello (--name defaults to $USER)",
            .sum = "add integers",
            .remote = "manage remotes",
        };
    };
};

const Greet = struct {
    name: ?[]const u8 = null,
    times: u32 = 1,

    pub const about = "Greet someone by name, repeated --times.";
    pub const descriptions = .{ .name = "who to greet", .times = "how many times" };
};

const Sum = struct {
    values: []const [:0]const u8,

    pub const about = "Sum the integer arguments.";
    pub const positionals = .{"values"};
    pub const descriptions = .{ .values = "integers to add" };
};

const Remote = union(enum) {
    add: Add,
    list: void,

    pub const about = "Register and list remotes.";
    pub const descriptions = .{ .add = "register a remote", .list = "show remotes" };

    const Add = struct {
        fetch: bool = false,
        name: []const u8,
        url: []const u8,

        pub const positionals = .{ "name", "url" };
        pub const descriptions = .{
            .fetch = "fetch immediately after adding",
            .name = "remote name",
            .url = "remote URL",
        };
    };
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var out_buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &out_buf);
    const w = &stdout.interface;

    // `demo --help` and `demo <command> --help` are handled before parsing;
    // `demo` with no arguments prints the top-level screen too.
    if (args.len < 2) {
        try w.writeAll(cli.help(Demo, "demo"));
        try w.flush();
        return;
    }
    if (cli.helpFor(Demo, "demo", args[1..])) |text| {
        try w.writeAll(text);
        try w.flush();
        return;
    }

    var p = cli.Parser.init(args[1..]);
    const demo = cli.parse(Demo, &p) catch |err| {
        std.log.err("{t} at '{s}'", .{ err, p.offending });
        try w.writeAll(cli.usage(Demo, "demo"));
        try w.writeByte('\n');
        try w.flush();
        std.process.exit(1);
    };

    run(w, init.environ_map, demo) catch |err| {
        std.log.err("{t}", .{err});
        try w.flush();
        std.process.exit(1);
    };
    try w.flush();
}

fn run(w: *std.Io.Writer, environ: *std.process.Environ.Map, demo: Demo) !void {
    if (demo.verbose) std.log.info("running '{s}'", .{@tagName(demo.command)});

    switch (demo.command) {
        .greet => |opts| {
            const who = opts.name orelse environ.get("USER") orelse "stranger";
            for (0..opts.times) |_| try w.print("hello, {s}!\n", .{who});
        },
        .sum => |opts| {
            var total: i64 = 0;
            for (opts.values) |value| {
                total += std.fmt.parseInt(i64, value, 10) catch return error.InvalidValue;
            }
            try w.print("{d}\n", .{total});
        },
        .remote => |remote| switch (remote) {
            .add => |add| try w.print("added remote {s} -> {s}{s}\n", .{
                add.name, add.url, if (add.fetch) " (fetching)" else "",
            }),
            .list => try w.writeAll("origin\nupstream\n"),
        },
    }
}
