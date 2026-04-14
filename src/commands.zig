const std = @import("std");
const Alloc = std.mem.Allocator;

pub const INPUT_MAX: comptime_int = 1024;

pub const Command = union(enum) {
    /// path, exec_cmd, daemonize, log_path
    Start: struct {
        path: []const u8,
        exec: []const u8,
        daemonize: bool,
        log_path: ?[]const u8,
    },
    /// force
    Stop: struct {
        force: bool,
    },
    Status,
    Help,
    Version,
};

pub fn parse(input: []const u8, allocator: std.mem.Allocator) !Command {
    var it = std.mem.tokenizeScalar(u8, input, ' ');
    const cmd = it.next() orelse return error.EmptyCommand;
    if (std.mem.eql(u8, "start", cmd)) {
        // Required: Path
        const path = try allocator.dupe(u8, it.next() orelse return error.MissingPath);
        // Optional Flags
        var daemonize = false;
        var log_path: ?[]const u8 = null;
        // Capture the rest as the execution command, or look for flags
        // For simplicity, we assume: start <path> <flags> <exec>
        // In a custom parser, you can be as granular as you want here.
        while (it.next()) |token| {
            if (std.mem.eql(u8, token, "--daemonize") or std.mem.eql(u8, token, "-d")) {
                daemonize = true;
            } else if (std.mem.eql(u8, token, "--log") or std.mem.eql(u8, token, "-l")) {
                const log = it.next() orelse return error.MissingLogPath;
                log_path = try allocator.dupe(u8, log);
            } else {
                // If it's not a known flag, treat it and everything after as the exec command
                // Note: it.rest() gets the original string remainder
                const rest = it.rest();
                const exec = try allocator.dupe(u8, rest);
                return Command{ .Start = .{
                    .path = path,
                    .exec = exec,
                    .daemonize = daemonize,
                    .log_path = log_path,
                } };
            }
        }
        return error.MissingExec;
    } else if (std.mem.eql(u8, "stop", cmd)) {
        var force = false;
        if (it.next()) |arg| {
            if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
                force = true;
            }
        }
        return Command{ .Stop = .{ .force = force } };
    } else if (std.mem.eql(u8, "status", cmd)) return Command.Status else if (std.mem.eql(u8, "help", cmd)) return Command.Help else if (std.mem.eql(u8, "version", cmd)) return Command.Version else return error.UnknownCommand;
}

pub fn toSocketMessage(self: Command, allocator: std.mem.Allocator) ![]const u8 {
    return switch (self) {
        .Start => |s| {
            const d_str = if (s.daemonize) "true" else "false";
            const l_str = s.log_path orelse "null";
            return try std.fmt.allocPrintZ(allocator, "start {s} {s} {s} {s}", .{ s.path, s.exec, d_str, l_str });
        },
        .Stop => |s| {
            return try std.fmt.allocPrintZ(allocator, "stop {any}", .{s.force});
        },
        .Status => try allocator.dupeZ(u8, "status"),
        .Help => try allocator.dupeZ(u8, "help"),
        .Version => try allocator.dupeZ(u8, "version"),
    };
}

pub fn getInput(dest: *[]u8, allocator: Alloc) !void {
    var reader = std.io.getStdIn().reader();
    const buf = try reader.readUntilDelimiterAlloc(allocator, '\n', INPUT_MAX);
    defer Alloc.free(allocator, buf);
    std.mem.copyForwards(u8, dest.*, buf);
}
