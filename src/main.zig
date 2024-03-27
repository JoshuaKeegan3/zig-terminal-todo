const std = @import("std");
const debug = std.debug;
const fs = std.fs;
const io = std.io;
const mem = std.mem;
const os = std.os;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

var cursor_y: usize = 0;
var size: Size = undefined;
var cooked_termios: os.termios = undefined;
var raw: os.termios = undefined;
var tty: fs.File = undefined;

var f: fs.File = undefined;
var it_size: usize = 0; // TODO: Refactor this out
var todos: ArrayList([]const u8) = undefined;
var in_progress: ArrayList([]const u8) = undefined;

var iter: std.mem.SplitIterator(u8, .sequence) = undefined;
var editing: bool = false;
pub fn todo() void {}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    todos = ArrayList([]const u8).init(alloc);
    in_progress = ArrayList([]const u8).init(alloc);

    const allocator = std.heap.page_allocator;
    var buff = try readFile(allocator, "/Users/Squashy/zig/todo/persistance/todo.txt");
    // var buff = try readFile(allocator, "persistance/todo.txt");
    defer allocator.free(buff);

    iter = std.mem.split(u8, buff, "\n");

    var args = std.process.args();
    _ = args.skip(); //to skip the zig call

    while (iter.peek() != null) {
        it_size += 1;
        var a = iter.next() orelse "";
        if (std.mem.startsWith(u8, a, "0")) {
            try todos.append(a[1..a.len]);
        } else if (std.mem.startsWith(u8, a, "1")) {
            try in_progress.append(a[1..a.len]);
        }
    }
    if (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "b")) {
            debug.print("TODO:\n", .{});
            for (todos.items) |txt| {
                debug.print("\t{s}\n", .{txt});
            }
            debug.print("In Progress:\n", .{});
            for (in_progress.items) |txt| {
                debug.print("\t{s}\n", .{txt});
            }
            return;
        }
    }

    tty = try fs.cwd().openFile("/dev/tty", .{ .mode = fs.File.OpenMode.read_write });
    defer tty.close();

    try uncook();
    defer cook() catch {};

    size = try getSize();

    try os.sigaction(os.SIG.WINCH, &os.Sigaction{
        .handler = .{ .handler = handleSigWinch },
        .mask = os.empty_sigset,
        .flags = 0,
    }, null);

    while (true) {
        try render();
        var buffer: [1]u8 = undefined;
        _ = try tty.read(&buffer);

        if (editing) {
            var index_mod: usize = 0;
            var list = todos;
            if (cursor_y >= todos.items.len) {
                list = in_progress;
                index_mod = todos.items.len;
            }
            switch (buffer[0]) {
                '\x1B' => {},
                '\x08', '\x7F' => {
                    if (cursor_y >= todos.items.len) {
                        list = in_progress;
                        index_mod = todos.items.len;
                    }
                    var item = list.orderedRemove(cursor_y - index_mod);
                    var result = try allocator.alloc(u8, item.len - 1);
                    mem.copy(u8, result[0..], item[0 .. item.len - 1]);
                    list.insert(cursor_y - index_mod, result) catch {};
                    try tty.writer().writeAll("\x1B[2J");
                },
                '\n' => {
                    editing = false;
                },
                else => {
                    var item = list.orderedRemove(cursor_y - index_mod);
                    var result = try allocator.alloc(u8, item.len + 1);
                    mem.copy(u8, result[0..], item);
                    mem.copy(u8, result[item.len..], &buffer);
                    list.insert(cursor_y - index_mod, result) catch {};
                },
            }
            continue;
        }
        switch (buffer[0]) {
            'q' => {
                try writeFile();
                return;
            },
            'K' => { //list_drag_up(&mut todos, &mut todo_curr),
                if (cursor_y < todos.items.len) {
                    if (cursor_y > 0) {
                        var val = todos.orderedRemove(cursor_y);
                        try todos.insert(cursor_y - 1, val);
                        cursor_y -= 1;
                    }
                } else {
                    if (cursor_y == todos.items.len) {
                        var val = in_progress.orderedRemove(0);
                        try todos.append(val);
                    } else {
                        var val = in_progress.orderedRemove(cursor_y - todos.items.len);
                        try in_progress.insert(cursor_y - todos.items.len - 1, val);
                        cursor_y -= 1;
                    }
                }
                try tty.writer().writeAll("\x1B[2J");
            },
            'J' => {
                if (cursor_y < todos.items.len) {
                    if (cursor_y == todos.items.len - 1) {
                        var val = todos.orderedRemove(todos.items.len - 1);
                        try in_progress.insert(0, val);
                    } else {
                        var val = todos.orderedRemove(cursor_y);
                        try todos.insert(cursor_y + 1, val);
                        cursor_y += 1;
                    }
                } else {
                    if (cursor_y < todos.items.len + in_progress.items.len - 1) {
                        var val = in_progress.orderedRemove(cursor_y - todos.items.len);
                        try in_progress.insert(cursor_y - todos.items.len + 1, val);
                        cursor_y += 1;
                    }
                }
                try tty.writer().writeAll("\x1B[2J");
            },
            'd' => {
                if (cursor_y < todos.items.len) {
                    _ = todos.swapRemove(cursor_y);
                } else {
                    _ = in_progress.swapRemove(cursor_y - todos.items.len);
                }
                if (cursor_y == todos.items.len + in_progress.items.len) {
                    cursor_y -= 1;
                }
                try tty.writer().writeAll("\x1B[2J");
            },
            'k' => cursor_y -|= 1,
            'j' => if (cursor_y < it_size - 2) {
                cursor_y = cursor_y + 1;
            },
            'a' => {
                if (cursor_y > todos.items.len) {
                    continue;
                }
                todos.insert(cursor_y, "") catch {};
                editing = true;
                try tty.writer().writeAll("\x1B[2J");
            },
            'r' => {
                editing = true;
                try tty.writer().writeAll("\x1B[2J");
            },
            '\n' => {
                if (cursor_y < todos.items.len) {
                    var item = todos.orderedRemove(cursor_y);
                    try in_progress.append(item);
                } else {
                    var item = in_progress.orderedRemove(cursor_y - todos.items.len);
                    try todos.append(item);
                }
                try tty.writer().writeAll("\x1B[2J");
            },
            '\t' => {
                if (cursor_y < todos.items.len) {
                    cursor_y = todos.items.len;
                } else {
                    cursor_y = 0;
                }
            },

            else => {},
        }
        if (buffer[0] == '\x1B') {
            raw.cc[os.system.V.TIME] = 1;
            raw.cc[os.system.V.MIN] = 0;
            try os.tcsetattr(tty.handle, .NOW, raw);

            var esc_buffer: [8]u8 = undefined;
            const esc_read = try tty.read(&esc_buffer);
            raw.cc[os.system.V.TIME] = 0;
            raw.cc[os.system.V.MIN] = 1;
            try os.tcsetattr(tty.handle, .NOW, raw);
            if (mem.eql(u8, esc_buffer[0..esc_read], "[A")) {
                cursor_y -|= 1;
            } else if (mem.eql(u8, esc_buffer[0..esc_read], "[B")) {
                if (cursor_y < it_size - 2) {
                    cursor_y = cursor_y + 1;
                }
            }
        }
    }
}
// cant be used in the same context as onther as the reader consums the value
fn isEscapeCode(code: []const u8) !bool {
    raw.cc[os.system.V.TIME] = 1;
    raw.cc[os.system.V.MIN] = 0;
    try os.tcsetattr(tty.handle, .NOW, raw);

    var esc_buffer: [8]u8 = undefined;
    const esc_read = try tty.read(&esc_buffer);
    raw.cc[os.system.V.TIME] = 0;
    raw.cc[os.system.V.MIN] = 1;
    try os.tcsetattr(tty.handle, .NOW, raw);
    return mem.eql(u8, esc_buffer[0..esc_read], code);
}

fn handleSigWinch(_: c_int) callconv(.C) void {
    size = getSize() catch return;
    render() catch return;
}

fn render() !void { // TODO: write only at curren location
    const writer = tty.writer();
    var i: usize = 0;
    try writeLine(writer, "TODO:", i, size.width, cursor_y == -1, false);
    i += 1;
    for (todos.items) |txt| {
        try writeLine(writer, txt, i, size.width, cursor_y == i - 1, true);
        i += 1;
    }
    try writeLine(writer, "In Progress:", i, size.width, cursor_y == -1, false);
    i += 1;
    for (in_progress.items) |txt| {
        try writeLine(writer, txt, i, size.width, cursor_y == i - 2, true);
        i += 1;
    }
    try attributeReset(writer);
}

fn writeLine(writer: anytype, txt: []const u8, y: usize, _: usize, selected: bool, selectable: bool) !void {
    try moveCursor(writer, y, 0);
    if (selected) {
        try setSelected(writer);
    } else {
        try attributeReset(writer);
    }
    if (selectable) {
        if (selected) {
            try writer.writeAll("-[x] ");
        } else {
            try writer.writeAll("-[ ] ");
        }
    }
    try writer.writeAll(txt);
    // try writer.writeByteNTimes(' ', width - txt.len);
}

fn uncook() !void {
    const writer = tty.writer();
    cooked_termios = try os.tcgetattr(tty.handle);
    errdefer cook() catch {};

    raw = cooked_termios;
    raw.lflag &= ~@as(
        os.system.tcflag_t,
        os.system.ECHO | os.system.ICANON | os.system.ISIG | os.system.IEXTEN,
    );
    raw.iflag &= ~@as(
        os.system.tcflag_t,
        os.system.IXON | os.system.BRKINT | os.system.INPCK | os.system.ISTRIP,
    );
    raw.oflag &= ~@as(os.system.tcflag_t, os.system.OPOST);
    raw.cflag |= os.system.CS8;
    raw.cc[os.system.V.TIME] = 0;
    raw.cc[os.system.V.MIN] = 1;
    try os.tcsetattr(tty.handle, .FLUSH, raw);

    try hideCursor(writer);
    try enterAlt(writer);
    try clear(writer);
}

fn cook() !void {
    const writer = tty.writer();
    try clear(writer);
    try leaveAlt(writer);
    try showCursor(writer);
    try attributeReset(writer);
    try os.tcsetattr(tty.handle, .FLUSH, cooked_termios);
}

fn moveCursor(writer: anytype, row: usize, col: usize) !void {
    _ = try writer.print("\x1B[{};{}H", .{ row + 1, col + 1 });
}

fn enterAlt(writer: anytype) !void {
    try writer.writeAll("\x1B[s"); // Save cursor position.
    try writer.writeAll("\x1B[?47h"); // Save screen.
    try writer.writeAll("\x1B[?1049h"); // Enable alternative buffer.
}

fn leaveAlt(writer: anytype) !void {
    try writer.writeAll("\x1B[?1049l"); // Disable alternative buffer.
    try writer.writeAll("\x1B[?47l"); // Restore screen.
    try writer.writeAll("\x1B[u"); // Restore cursor position.
}

fn hideCursor(writer: anytype) !void {
    try writer.writeAll("\x1B[?25l");
}

fn showCursor(writer: anytype) !void {
    try writer.writeAll("\x1B[?25h");
}

fn attributeReset(writer: anytype) !void {
    try writer.writeAll("\x1B[0m");
}

fn setSelected(writer: anytype) !void {
    try writer.writeAll("\x1B[30m");
    if (editing) {
        try writer.writeAll("\x1B[41m");
    } else {
        try writer.writeAll("\x1B[47m");
    }
}

fn clear(writer: anytype) !void {
    try writer.writeAll("\x1B[2J");
}

const Size = struct { width: usize, height: usize };

fn getSize() !Size {
    var win_size = mem.zeroes(os.system.winsize);
    const dim: Size = .{
        .height = win_size.ws_row,
        .width = win_size.ws_col,
    };
    return dim;
}

fn readFile(allocator: Allocator, filename: []const u8) ![]u8 {
    // const file = fs.openFileAbsolute(filename, .{ .mode = fs.File.OpenMode.read_only });

    const file = try std.fs.cwd().openFile(
        filename,
        .{ .mode = fs.File.OpenMode.read_only },
    );
    defer file.close();
    const stat = try file.stat();
    var buff = try file.readToEndAlloc(allocator, stat.size);
    return buff;
}

fn writeFile() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var bytes = ArrayList(u8).init(arena.allocator());
    defer bytes.deinit();
    for (todos.items) |byte| {
        _ = try bytes.writer().write("0");
        _ = try bytes.writer().write(byte);
        _ = try bytes.writer().write("\n");
    }
    for (in_progress.items) |byte| {
        _ = try bytes.writer().write("1");
        _ = try bytes.writer().write(byte);
        _ = try bytes.writer().write("\n");
    }

    const file = try std.fs.cwd().createFile("/Users/Squashy/zig/todo/persistance/todo.txt", .{ .read = true });
    defer file.close();

    try file.writeAll(bytes.items);
}
