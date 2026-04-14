const std = @import("std");
const prev_file_path = "watcher/prev.json";
const changed_files_path = "watcher/changed_files.txt";
const FileHashes = std.StringHashMap([]const u8);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const stdout = std.io.getStdOut().writer();
    if (args.len < 2) {
        try printHelp(stdout);
        std.process.exit(1);
    }
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "init")) {
        initWatcher() catch |err| {
            try stdout.print("Error initializing watcher structure: {any}\n", .{err});
            std.process.exit(1);
        };
        try stdout.print("Watcher initialized successfully!\n", .{});
        return;
    }
    else if (std.mem.eql(u8, cmd, "help")) {
        try printHelp(stdout);
        return;
    }
    else if (std.mem.eql(u8, cmd, "clear")) {
        clearPrevJson() catch |err| {
            try stdout.print("Error clearing 'prev.json': {any}\n", .{err});
            std.process.exit(1);
        };
        try stdout.print("'prev.json' cleared successfully!\n", .{});
        return;
    }
    // Treat argument as a directory path to watch.
    const path = cmd;
    var prev_hashes = try loadPrevHashes(allocator);
    defer freeHashes(allocator, &prev_hashes);
    var curr_hashes = try computeHashes(allocator, path);
    defer freeHashes(allocator, &curr_hashes);
    var latest_changes = FileHashes.init(allocator);
    defer freeHashes(allocator, &latest_changes);
    // New or changed files.
    var curr_it = curr_hashes.iterator();
    while (curr_it.next()) |entry| {
        const file = entry.key_ptr.*;
        const curr_hash = entry.value_ptr.*;
        if (prev_hashes.get(file)) |prev_hash| {
            if (!std.mem.eql(u8, prev_hash, curr_hash)) {
                try latest_changes.put(
                    try allocator.dupe(u8, file),
                    try allocator.dupe(u8, curr_hash),
                );
            }
        }
        else {
            try latest_changes.put(
                try allocator.dupe(u8, file),
                try allocator.dupe(u8, curr_hash),
            );
        }
    }
    // Deleted files (empty string marks deletion, matching Go behaviour).
    var prev_it = prev_hashes.iterator();
    while (prev_it.next()) |entry| {
        if (!curr_hashes.contains(entry.key_ptr.*)) {
            try latest_changes.put(
                try allocator.dupe(u8, entry.key_ptr.*),
                try allocator.dupe(u8, ""),
            );
        }
    }
    const changed = try saveHashes(allocator, &curr_hashes, &latest_changes);
    if (!changed) {
        try writeTxtFile(&latest_changes);
        try stdout.print("No changes detected. 'changed_files.txt' cleared.\n", .{});
    }
    else {
        try stdout.print("Changed files:\n", .{});
        var it = latest_changes.iterator();
        while (it.next()) |entry| {
            try stdout.print("{s}\n", .{entry.key_ptr.*});
        }
        try stdout.print("\nFiles written to 'watcher/changed_files.txt'.\n", .{});
    }
}

// computeHashes walks dir_path recursively, hashing every file except those
// inside a "watcher" subdirectory (mirrors Go's filepath.SkipDir logic).
fn computeHashes(allocator: std.mem.Allocator, dir_path: []const u8) !FileHashes {
    var hashes = FileHashes.init(allocator);
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        // Skip the watcher/ directory and everything inside it.
        if (std.mem.eql(u8, entry.path, "watcher") or
            std.mem.startsWith(u8, entry.path, "watcher/") or
            std.mem.startsWith(u8, entry.path, "watcher\\")) continue;
        if (entry.kind != .file) continue;
        const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.path });
        errdefer allocator.free(full_path);
        const hash = hashFile(allocator, full_path) catch |err| {
            std.debug.print("Error hashing file {s}: {any}\n", .{ full_path, err });
            allocator.free(full_path);
            continue;
        };
        try hashes.put(full_path, hash);
    }
    return hashes;
}

// hashFile returns the lowercase hex-encoded SHA-256 of the file at path.
fn hashFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.allocPrint(allocator, "{}", .{std.fmt.fmtSliceHexLower(&digest)});
}

// loadPrevHashes reads watcher/prev.json and returns its contents as a map.
// Returns an empty map if the file does not exist.
fn loadPrevHashes(allocator: std.mem.Allocator) !FileHashes {
    var hashes = FileHashes.init(allocator);
    const data = std.fs.cwd().readFileAlloc(allocator, prev_file_path, 100 * 1024 * 1024) catch |err| {
        if (err == error.FileNotFound) return hashes;
        return err;
    };
    defer allocator.free(data);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();
    switch (parsed.value) {
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |e| {
                const key = try allocator.dupe(u8, e.key_ptr.*);
                const val = switch (e.value_ptr.*) {
                    .string => |s| try allocator.dupe(u8, s),
                    else => try allocator.dupe(u8, ""),
                };
                try hashes.put(key, val);
            }
        },
        else => {},
    }
    return hashes;
}

// saveHashes writes curr_hashes to prev.json and calls writeTxtFile for the
// changed set. Returns false (and skips the write) when nothing changed.
fn saveHashes(
    allocator: std.mem.Allocator,
    curr_hashes: *const FileHashes,
    changed_hashes: *const FileHashes,
) !bool {
    if (changed_hashes.count() == 0) return false;
    // Build a std.json.Value so we can use the standard JSON serialiser.
    var obj = std.json.ObjectMap.init(allocator);
    defer obj.deinit();
    var it = curr_hashes.iterator();
    while (it.next()) |entry| {
        try obj.put(entry.key_ptr.*, std.json.Value{ .string = entry.value_ptr.* });
    }
    const value = std.json.Value{ .object = obj };
    const file = std.fs.cwd().createFile(prev_file_path, .{}) catch |err| {
        std.debug.print(
            "Error: {any}.\nPlease run `watcher init` to generate necessary files.\n",
            .{err},
        );
        std.process.exit(1);
    };
    defer file.close();
    try std.json.stringify(value, .{ .whitespace = .indent_2 }, file.writer());
    try writeTxtFile(changed_hashes);
    return true;
}

// writeTxtFile writes one file path per line to watcher/changed_files.txt.
// Passing an empty map clears the file (used when there are no changes).
fn writeTxtFile(hashes: *const FileHashes) !void {
    const file = try std.fs.cwd().createFile(changed_files_path, .{});
    defer file.close();
    var bw = std.io.bufferedWriter(file.writer());
    var it = hashes.iterator();
    while (it.next()) |entry| {
        try bw.writer().print("{s}\n", .{entry.key_ptr.*});
    }
    try bw.flush();
}

// initWatcher creates the watcher/ directory and its two required files.
fn initWatcher() !void {
    std.fs.cwd().makeDir("watcher") catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
    const json_file = try std.fs.cwd().createFile(prev_file_path, .{});
    defer json_file.close();
    try json_file.writeAll("{}");
    const txt_file = try std.fs.cwd().createFile(changed_files_path, .{});
    defer txt_file.close();
}

// clearPrevJson resets prev.json to an empty object.
fn clearPrevJson() !void {
    const file = try std.fs.cwd().createFile(prev_file_path, .{});
    defer file.close();
    try file.writeAll("{}");
}

fn printHelp(writer: anytype) !void {
    try writer.writeAll(
        \\Welcome to the file watcher help menu!
        \\
        \\Usage: watcher <directory_path> OR <command>
        \\
        \\Valid commands:
        \\help  - Shows this menu.
        \\init  - Generate the necessary directory structure for the tool.
        \\clear - Clears 'prev.json' in case it gets corrupted.
        \\        Running the tool again will repopulate it.
        \\
    );
}

// freeHashes frees all keys and values stored in the map, then deinits it.
fn freeHashes(allocator: std.mem.Allocator, hashes: *FileHashes) void {
    var it = hashes.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    hashes.deinit();
}

