const std = @import("std");

pub fn println(text: []const u8) void {
    const writer = std.io.getStdOut().writer();
    writer.print("{s}\n", .{text}) catch |err| {
        std.debug.print("Error printing: {any}\n", .{err});
    };
}

pub fn daemonize(log_path: []const u8, redirect_stdout: bool) !void {
    // First fork
    const fork_result = try std.posix.fork();
    if (fork_result < 0) return error.ForkFailed;
    if (fork_result > 0) std.posix.exit(0); // Parent exits
    // Start new session
    _ = std.os.linux.setsid();
    // Optional second fork (for double-fork daemonization)
    // const fork_result2 = try std.posix.fork();
    // if (fork_result2 > 0) std.posix.exit(0); // Optional double-fork
    // Redirect stdio to a log file
    const file = try std.fs.cwd().createFile(log_path, .{
        .truncate = true,
        .read = true,
    });
    const fd = file.handle;
    try std.posix.dup2(fd, std.io.getStdIn().handle);
    try std.posix.dup2(fd, std.io.getStdErr().handle);
    if (redirect_stdout) {
        try std.posix.dup2(fd, std.io.getStdOut().handle);
    }
    // Optionally: chdir to root to avoid blocking filesystem unmounts
    try std.posix.chdir("/");
}

