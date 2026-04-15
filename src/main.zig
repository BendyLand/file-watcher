const std = @import("std");

const watcher_dir = ".watcher";
const index_path = ".watcher/.index";
// maps path_hash (hex) -> contents_hash (hex), loaded from .watcher/ filenames.
const HashPairMap = std.StringHashMap([]const u8);
// maps path_hash (hex) -> original file path, loaded from .watcher/.index.
const IndexMap = std.StringHashMap([]const u8);
const FileInfo = struct {
    path: []const u8,
    contents_hash: []const u8,
};
// maps path_hash (hex) -> FileInfo for all files found in the watched directory.
const CurrentFilesMap = std.StringHashMap(FileInfo);

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
            try stdout.print("Error initializing watcher: {any}\n", .{err});
            std.process.exit(1);
        };
        try stdout.print("Watcher initialized.\n", .{});
        return;
    }
    else if (std.mem.eql(u8, cmd, "help")) {
        try printHelp(stdout);
        return;
    }
    else if (std.mem.eql(u8, cmd, "clear") or std.mem.eql(u8, cmd, "clean")) {
        clearWatcher(allocator) catch |err| {
            try stdout.print("Error clearing watcher state: {any}\n", .{err});
            std.process.exit(1);
        };
        try stdout.print("Watcher state cleared.\n", .{});
        return;
    }
    // parse flags and directory path from remaining args.
    var include_hidden = false;
    var null_separated = false;
    var watch_path: ?[]const u8 = null;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--hidden") or std.mem.eql(u8, arg, "-h")) {
            include_hidden = true;
        }
        else if (std.mem.eql(u8, arg, "--null") or std.mem.eql(u8, arg, "-0")) {
            null_separated = true;
        }
        else {
            watch_path = arg;
        }
    }
    if (watch_path == null) {
        try stdout.print("Error: no directory path provided.\n", .{});
        std.process.exit(1);
    }
    // load existing state: scan .watcher/ filenames -> path_hash:contents_hash pairs.
    var prev_state = loadWatcherState(allocator) catch |err| {
        if (err == error.FileNotFound) {
            try stdout.print(
                "Error: '{s}' not found. Run `watcher init` first.\n",
                .{watcher_dir},
            );
            std.process.exit(1);
        }
        return err;
    };
    defer freeStrMap(allocator, &prev_state);
    // load .index: path_hash -> original path (needed to report deleted file paths).
    var prev_index = try loadIndex(allocator);
    defer freeStrMap(allocator, &prev_index);
    // compute current state by walking the watched directory.
    var current = try computeCurrentFiles(allocator, watch_path.?, include_hidden);
    defer {
        var it = current.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*.path);
            allocator.free(e.value_ptr.*.contents_hash);
        }
        current.deinit();
    }
    // collect changed paths.
    var changed_paths = std.ArrayList([]const u8).init(allocator);
    defer changed_paths.deinit();
    // added / modified files.
    var curr_it = current.iterator();
    while (curr_it.next()) |e| {
        const path_hash = e.key_ptr.*;
        const info = e.value_ptr.*;
        if (prev_state.get(path_hash)) |old_hash| {
            if (!std.mem.eql(u8, old_hash, info.contents_hash)) {
                try changed_paths.append(info.path);
            }
        }
        else {
            try changed_paths.append(info.path);
        }
    }
    // deleted files: anything in the index that no longer appears on disk.
    var idx_it = prev_index.iterator();
    while (idx_it.next()) |e| {
        if (!current.contains(e.key_ptr.*)) {
            try changed_paths.append(e.value_ptr.*);
        }
    }
    if (changed_paths.items.len > 0) {
        try updateWatcherState(allocator, &prev_state, &current);
        if (null_separated) {
            for (changed_paths.items) |path| {
                try stdout.writeAll(path);
                try stdout.writeByte(0);
            }
        }
        else {
            for (changed_paths.items, 0..) |path, i| {
                if (i > 0) try stdout.writeByte(' ');
                try stdout.writeAll(path);
            }
            try stdout.writeByte('\n');
        }
    }
}

// Returns true if any component of a path (separated by / or \) starts with '.'.
fn hasHiddenComponent(path: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |component| {
        if (component.len > 0 and component[0] == '.') return true;
    }
    return false;
}

fn freeStrMap(allocator: std.mem.Allocator, map: *std.StringHashMap([]const u8)) void {
    var it = map.iterator();
    while (it.next()) |e| {
        allocator.free(e.key_ptr.*);
        allocator.free(e.value_ptr.*);
    }
    map.deinit();
}

// hashBytes returns the lowercase hex SHA-256 of an arbitrary byte slice.
fn hashBytes(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(bytes);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    h.final(&digest);
    return std.fmt.allocPrint(allocator, "{}", .{std.fmt.fmtSliceHexLower(&digest)});
}

// hashFile returns the lowercase hex SHA-256 of a file's contents.
fn hashFile(allocator: std.mem.Allocator, file_path: []const u8) ![]const u8 {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;
        h.update(buf[0..n]);
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    h.final(&digest);
    return std.fmt.allocPrint(allocator, "{}", .{std.fmt.fmtSliceHexLower(&digest)});
}

// computeCurrentFiles walks dir_path and returns a map of
//   path_hash -> { original_path, contents_hash }
// skipping the .watcher/ subdirectory.
fn computeCurrentFiles(allocator: std.mem.Allocator, dir_path: []const u8, include_hidden: bool) !CurrentFilesMap {
    var files = CurrentFilesMap.init(allocator);
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (std.mem.eql(u8, entry.path, ".watcher") or
            std.mem.startsWith(u8, entry.path, ".watcher/") or
            std.mem.startsWith(u8, entry.path, ".watcher\\")) continue;
        if (!include_hidden and hasHiddenComponent(entry.path)) continue;
        if (entry.kind != .file) continue;
        const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.path });
        errdefer allocator.free(full_path);
        const path_hash = try hashBytes(allocator, full_path);
        errdefer allocator.free(path_hash);
        const contents_hash = hashFile(allocator, full_path) catch |err| {
            std.debug.print("Warning: could not hash {s}: {any}\n", .{ full_path, err });
            allocator.free(full_path);
            allocator.free(path_hash);
            continue;
        };
        errdefer allocator.free(contents_hash);
        try files.put(path_hash, .{ .path = full_path, .contents_hash = contents_hash });
    }
    return files;
}

// loadWatcherState scans .watcher/ and builds path_hash -> contents_hash from
// each filename formatted as "<path_hash>:<contents_hash>".
fn loadWatcherState(allocator: std.mem.Allocator) !HashPairMap {
    var state = HashPairMap.init(allocator);
    var dir = try std.fs.cwd().openDir(watcher_dir, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (entry.name.len == 0 or entry.name[0] == '.') continue; // skip .index
        const sep = std.mem.indexOf(u8, entry.name, ":") orelse continue;
        const path_hash = try allocator.dupe(u8, entry.name[0..sep]);
        errdefer allocator.free(path_hash);
        const contents_hash = try allocator.dupe(u8, entry.name[sep + 1 ..]);
        try state.put(path_hash, contents_hash);
    }
    return state;
}

// loadIndex reads .watcher/.index and builds path_hash -> original_path.
// each line is: "<path_hash> <original_path>"
fn loadIndex(allocator: std.mem.Allocator) !IndexMap {
    var index = IndexMap.init(allocator);
    const data = std.fs.cwd().readFileAlloc(allocator, index_path, 100 * 1024 * 1024) catch |err| {
        if (err == error.FileNotFound) return index;
        return err;
    };
    defer allocator.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r");
        if (trimmed.len == 0) continue;
        const sp = std.mem.indexOf(u8, trimmed, " ") orelse continue;
        const path_hash = try allocator.dupe(u8, trimmed[0..sp]);
        errdefer allocator.free(path_hash);
        const orig_path = try allocator.dupe(u8, trimmed[sp + 1 ..]);
        try index.put(path_hash, orig_path);
    }
    return index;
}

// updateWatcherState removes stale hash files, creates new hash files for
// new/changed entries, and rewrites .watcher/.index to reflect current_files.
fn updateWatcherState(
    allocator: std.mem.Allocator,
    prev_state: *const HashPairMap,
    current_files: *const CurrentFilesMap,
) !void {
    var wd = std.fs.cwd().openDir(watcher_dir, .{}) catch |err| {
        std.debug.print(
            "Error: {any}.\nPlease run `watcher init` to generate necessary files.\n",
            .{err},
        );
        std.process.exit(1);
    };
    defer wd.close();
    // delete hash files for entries that changed or were removed.
    var prev_it = prev_state.iterator();
    while (prev_it.next()) |e| {
        const path_hash = e.key_ptr.*;
        const old_hash = e.value_ptr.*;
        const stale = if (current_files.get(path_hash)) |info|
            !std.mem.eql(u8, info.contents_hash, old_hash)
        else
            true;
        if (!stale) continue;
        const filename = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ path_hash, old_hash });
        defer allocator.free(filename);
        wd.deleteFile(filename) catch |err| {
            std.debug.print("Warning: could not remove {s}: {any}\n", .{ filename, err });
        };
    }
    // create hash files for new or changed entries.
    var curr_it = current_files.iterator();
    while (curr_it.next()) |e| {
        const path_hash = e.key_ptr.*;
        const info = e.value_ptr.*;
        const changed = if (prev_state.get(path_hash)) |old_hash|
            !std.mem.eql(u8, old_hash, info.contents_hash)
        else
            true;
        if (!changed) continue;
        const filename = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ path_hash, info.contents_hash });
        defer allocator.free(filename);
        const f = try wd.createFile(filename, .{});
        f.close();
    }
    // rewrite .index atomically: write to a temp file then rename into place.
    const tmp_path = watcher_dir ++ "/.index.tmp";
    {
        const tmp_file = try std.fs.cwd().createFile(tmp_path, .{});
        errdefer std.fs.cwd().deleteFile(tmp_path) catch {};
        var bw = std.io.bufferedWriter(tmp_file.writer());
        var idx_it = current_files.iterator();
        while (idx_it.next()) |e| {
            try bw.writer().print("{s} {s}\n", .{ e.key_ptr.*, e.value_ptr.*.path });
        }
        try bw.flush();
        tmp_file.close();
    }
    try std.fs.cwd().rename(tmp_path, index_path);
}

fn initWatcher() !void {
    std.fs.cwd().makeDir(watcher_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
    const index_file = try std.fs.cwd().createFile(index_path, .{});
    index_file.close();
}

// clearWatcher deletes all hash files from .watcher/ and empties .index,
// so the next run treats every file as new.
fn clearWatcher(allocator: std.mem.Allocator) !void {
    var dir = try std.fs.cwd().openDir(watcher_dir, .{ .iterate = true });
    defer dir.close();
    // collect names first; deleting while iterating is unsafe.
    var to_delete = std.ArrayList([]const u8).init(allocator);
    defer {
        for (to_delete.items) |name| allocator.free(name);
        to_delete.deinit();
    }
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        try to_delete.append(try allocator.dupe(u8, entry.name));
    }
    for (to_delete.items) |name| {
        dir.deleteFile(name) catch |err| {
            std.debug.print("Warning: could not delete {s}: {any}\n", .{ name, err });
        };
    }
    const index_file = try std.fs.cwd().createFile(index_path, .{});
    index_file.close();
}

fn printHelp(writer: anytype) !void {
    try writer.writeAll(
        \\Usage: watcher [options] <directory_path>
        \\       watcher <command>
        \\
        \\Options:
        \\  -h, --hidden  Include hidden files and directories (dotfiles).
        \\  -0, --null    Separate output paths with null bytes instead of spaces.
        \\
        \\Commands:
        \\  init   Create the .watcher/ state directory.
        \\  clear  Reset tracked state; next run treats every file as new.
        \\  help   Show this message.
        \\
        \\On each run, prints space-separated paths of changed files to stdout,
        \\then updates the stored state. Prints nothing if no changes are detected.
        \\Dotfiles are ignored by default.
        \\
    );
}

