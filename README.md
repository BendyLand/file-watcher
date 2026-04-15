# File Watcher

A basic file watcher written in Zig!

## About

This tool was originally created for my build tool `blmake`, to watch for when specifically C/C++ files change as a way to implement incremental recompilation.

However, I ended up liking the project more than I thought I would, so I decided to make a standalone version that works on all file types and traverses recursively.

The tool tracks state in a `.watcher/` directory using content-addressed hash files and a `.watcher/.index` mapping. On each run it prints the space-separated paths of any changed (added, modified, or deleted) files to stdout, then updates the stored state. Nothing is printed when no changes are detected.

Hidden files and dotfiles are ignored by default.

## Usage
```bash
watcher [--hidden] <directory_path>
watcher <command>
```

**Options:**
 - `-h`, `--hidden` - Include hidden files and directories (dotfiles).

**Commands:**
 - `help`  - Show the help message.
 - `init`  - Create the `.watcher/` state directory.
 - `clear` / `clean` - Reset tracked state; the next run treats every file as new.

### Quick Start

```bash
watcher init
watcher .        # or any other directory you want to watch
# Subsequent runs will detect and print changed files
```


