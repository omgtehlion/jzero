const std = @import("std");
const vx = @import("vaxis");
const wcwidth = @import("wcwidth");

pub const stNormal: u16 = 1;
pub const stSelected: u16 = 2;
pub const stKey: u16 = 3;
pub const stValue: u16 = 4;
pub const stWilderness: u16 = 5;
pub const stScroll: u16 = 6;
pub const stScrollBk: u16 = 7;
pub const stStatBar: u16 = 8;
pub const stSearch: u16 = 9;
pub const stMatchActive: u16 = 10;
pub const stMatchInactive: u16 = 11;
pub const stLoading: u16 = 12;
pub const stLoaded: u16 = 13;
pub const stHelp: u16 = 14;

const styleMap = [stHelp + 1]vx.Cell.Style{
    .{}, // 0 - unused
    .{},
    .{ .reverse = true },
    .{ .bold = true, .fg = .{ .index = 6 } },
    .{ .bold = true, .fg = .{ .index = 2 } },
    .{ .fg = .{ .index = 4 } },
    .{ .fg = .{ .index = 15 } },
    .{ .fg = .{ .index = 7 } },
    .{ .fg = .{ .index = 0 }, .bg = .{ .index = 7 } },
    .{},
    .{ .fg = .{ .index = 1 }, .bg = .{ .index = 7 } },
    .{ .fg = .{ .index = 0 }, .bg = .{ .index = 3 } },
    .{ .fg = .{ .index = 7 }, .bg = .{ .index = 4 } },
    .{ .fg = .{ .index = 15 }, .bg = .{ .index = 4 } },
    .{ .bold = true, .fg = .{ .index = 3 }, .bg = .{ .index = 7 } },
};

pub const key = struct {
    pub const KEY_ESC: u16 = 27;
    pub const KEY_UP: u16 = 0x1001;
    pub const KEY_DOWN: u16 = 0x1002;
    pub const KEY_LEFT: u16 = 0x1003;
    pub const KEY_RIGHT: u16 = 0x1004;
    pub const KEY_HOME: u16 = 0x1005;
    pub const KEY_END: u16 = 0x1006;
    pub const KEY_PPAGE: u16 = 0x1007;
    pub const KEY_NPAGE: u16 = 0x1008;
    pub const KEY_F1: u16 = 0x1101;
};

pub const Point = struct { y: u16, x: u16 };
pub const MouseInfo = struct { y: u16, x: u16, buttons: u16 };
pub const ControlKeys = vx.Key.Modifiers;
pub const InputEvent = struct {
    data: union(enum) { char: u32, key: u16, resize: void, mouse: *MouseInfo },
    keys: ControlKeys = .{},
};

pub var COLS: u16 = 0;
pub var ROWS: u16 = 0;
pub var input: std.fs.File.Handle = undefined; // used by linenoise
pub var output: std.fs.File.Handle = undefined;

var ttyInst: vx.Tty = undefined;
var vaxisInst: vx.Vaxis = undefined;
var loopInst: vx.Loop(vx.Event) = undefined;
var loopRunning: bool = false;

var cursor: Point = .{ .x = 0, .y = 0 };
var savedCursor: Point = .{ .x = 0, .y = 0 };
var curStyle: u16 = stNormal;
var cursorVisible: bool = false;
var mouseInfo: MouseInfo = .{ .y = 0, .x = 0, .buttons = 0 };

const maxRows: u16 = 250;
const maxCols: u16 = 400;
// vaxis does not make internal copies, so we need a backing buffer
var charBuf = std.mem.zeroes([maxRows][maxCols][4]u8);

pub fn init() !void {
    ttyInst = try vx.Tty.init();
    input = ttyInst.fd;
    output = ttyInst.fd;

    vaxisInst = try vx.init(std.heap.page_allocator, .{});

    const ws = try vx.Tty.getWinsize(output);
    ROWS = @min(ws.rows, maxRows);
    COLS = @min(ws.cols, maxCols);

    try vaxisInst.enterAltScreen(ttyInst.anyWriter());
    try vaxisInst.setMouseMode(ttyInst.anyWriter(), true);
    try ttyInst.anyWriter().writeAll("\x1b[?25l"); // hide cursor initially
    try vaxisInst.resize(std.heap.page_allocator, ttyInst.anyWriter(), .{
        .rows = ROWS,
        .cols = COLS,
        .x_pixel = ws.x_pixel,
        .y_pixel = ws.y_pixel,
    });
    loopInst = .{ .tty = &ttyInst, .vaxis = &vaxisInst };
    try loopInst.init();
    try loopInst.start();
    loopRunning = true;
}

pub fn deinit() void {
    if (loopRunning) {
        loopInst.stop();
        loopRunning = false;
    }
    vaxisInst.deinit(std.heap.page_allocator, ttyInst.anyWriter());
    ttyInst.deinit();
}

pub fn showCursor(show: bool) void {
    // Stop the loop so linenoise can own the tty exclusively.
    cursorVisible = show;
    if (show) {
        if (loopRunning) {
            loopInst.stop();
            loopRunning = false;
        }
        _ = ttyInst.anyWriter().writeAll("\x1b[?25h") catch {};
    } else {
        _ = ttyInst.anyWriter().writeAll("\x1b[?25l") catch {};
    }
}

pub fn refreshSize() void {
    // Called after linenoise returns. Restarts the loop and forces full redraw.
    const ws = vx.Tty.getWinsize(output) catch return;
    ROWS = @min(ws.rows, maxRows);
    COLS = @min(ws.cols, maxCols);
    vaxisInst.resize(std.heap.page_allocator, ttyInst.anyWriter(), .{
        .rows = ROWS,
        .cols = COLS,
        .x_pixel = ws.x_pixel,
        .y_pixel = ws.y_pixel,
    }) catch return;
    if (!loopRunning) {
        loopInst.start() catch return;
        loopRunning = true;
    }
}

pub fn move(y: u16, x: u16) void {
    cursor.y = @min(y, maxRows - 1);
    cursor.x = @min(x, maxCols - 1);
}

pub fn getcurx() u16 {
    return cursor.x;
}

pub fn style(s: u16) void {
    curStyle = if (s < styleMap.len) s else stNormal;
}

pub fn saveCursor() void {
    savedCursor = cursor;
}

pub fn restoreCursor() void {
    cursor = savedCursor;
}

fn charWidth(cp: u32) u16 {
    if (cp > std.math.maxInt(u21)) return 1;
    const w = wcwidth.wcwidth(@intCast(cp));
    return if (w > 1) 2 else 1;
}

fn writeChar(cp: u32) void {
    if (cursor.y >= maxRows or cursor.x >= maxCols) return;
    var bytes: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(@intCast(cp), &bytes) catch blk: {
        bytes[0] = '?';
        break :blk @as(u3, 1);
    };
    const w = charWidth(cp);
    charBuf[cursor.y][cursor.x] = bytes;
    vaxisInst.screen.writeCell(cursor.x, cursor.y, .{
        .char = .{ .grapheme = charBuf[cursor.y][cursor.x][0..len], .width = @intCast(w) },
        .style = styleMap[curStyle],
    });
    if (w >= 2 and cursor.x + 1 < maxCols) {
        vaxisInst.screen.writeCell(cursor.x + 1, cursor.y, .{});
    }
    cursor.x += w;
}

pub fn addnstr(text: []const u8) void {
    var i: usize = 0;
    while (i < text.len and cursor.x < maxCols) {
        const seqLen = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            writeChar('?');
            i += 1;
            continue;
        };
        if (i + seqLen > text.len) break;
        const cp = std.unicode.utf8Decode(text[i..][0..seqLen]) catch '?';
        writeChar(cp);
        i += seqLen;
    }
}

pub fn addnstrto(text: []const u8, right: u16) void {
    var i: usize = 0;
    while (i < text.len and cursor.x < right and cursor.x < maxCols) {
        const seqLen = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            if (cursor.x < right) writeChar('?');
            i += 1;
            continue;
        };
        if (i + seqLen > text.len) break;
        const cp = std.unicode.utf8Decode(text[i..][0..seqLen]) catch '?';
        if (cursor.x + charWidth(cp) > right) break;
        writeChar(cp);
        i += seqLen;
    }
}

pub fn mvhline(y: u16, x: u16, ch: u8, count: u16, newStyle: u16) void {
    style(newStyle);
    cursor.y = @min(y, maxRows - 1);
    cursor.x = @min(x, maxCols - 1);
    var c = cursor.x;
    var n: u16 = 0;
    while (n < count and c < maxCols) : ({
        n += 1;
        c += 1;
    }) {
        charBuf[cursor.y][c] = .{ ch, 0, 0, 0 };
        vaxisInst.screen.writeCell(c, cursor.y, .{
            .char = .{ .grapheme = charBuf[cursor.y][c][0..1], .width = 1 },
            .style = styleMap[curStyle],
        });
    }
    cursor.x = c;
}

const vtWriter = std.io.Writer(void, error{}, struct {
    fn write(_: void, bytes: []const u8) error{}!usize {
        addnstr(bytes);
        return bytes.len;
    }
}.write){ .context = {} };

pub fn mvstyleprint(y: u16, x: u16, s: u16, comptime fmt: []const u8, args: anytype) void {
    move(y, x);
    style(s);
    std.fmt.format(vtWriter, fmt, args) catch {};
}

pub fn refresh() void {
    vaxisInst.screen.cursor_vis = cursorVisible;
    if (cursorVisible) {
        vaxisInst.screen.cursor_row = cursor.y;
        vaxisInst.screen.cursor_col = cursor.x;
    }
    vaxisInst.render(ttyInst.anyWriter()) catch {};
}

pub fn getch() InputEvent {
    while (true) {
        const ev = loopInst.nextEvent();
        switch (ev) {
            .key_press => |k| {
                const ctrl = k.mods;
                const cp = k.codepoint;
                if (cp == vx.Key.escape) return .{ .data = .{ .key = key.KEY_ESC }, .keys = ctrl };
                if (cp == vx.Key.up) return .{ .data = .{ .key = key.KEY_UP }, .keys = ctrl };
                if (cp == vx.Key.down) return .{ .data = .{ .key = key.KEY_DOWN }, .keys = ctrl };
                if (cp == vx.Key.left) return .{ .data = .{ .key = key.KEY_LEFT }, .keys = ctrl };
                if (cp == vx.Key.right) return .{ .data = .{ .key = key.KEY_RIGHT }, .keys = ctrl };
                if (cp == vx.Key.home) return .{ .data = .{ .key = key.KEY_HOME }, .keys = ctrl };
                if (cp == vx.Key.end) return .{ .data = .{ .key = key.KEY_END }, .keys = ctrl };
                if (cp == vx.Key.page_up) return .{ .data = .{ .key = key.KEY_PPAGE }, .keys = ctrl };
                if (cp == vx.Key.page_down) return .{ .data = .{ .key = key.KEY_NPAGE }, .keys = ctrl };
                if (cp == vx.Key.f1) return .{ .data = .{ .key = key.KEY_F1 }, .keys = ctrl };
                return .{ .data = .{ .char = cp }, .keys = ctrl };
            },
            .mouse => |m| {
                const bit: u16 = switch (m.button) {
                    .left => 0x01,
                    .middle => 0x02,
                    .right => 0x04,
                    else => 0,
                };
                if (m.type == .press)
                    mouseInfo.buttons |= bit
                else if (m.type == .release)
                    mouseInfo.buttons &= ~bit;
                mouseInfo.x = m.col;
                mouseInfo.y = m.row;
                return .{ .data = .{ .mouse = &mouseInfo } };
            },
            .winsize => |ws| {
                ROWS = @min(ws.rows, maxRows);
                COLS = @min(ws.cols, maxCols);
                vaxisInst.resize(std.heap.page_allocator, ttyInst.anyWriter(), .{
                    .rows = ROWS,
                    .cols = COLS,
                    .x_pixel = ws.x_pixel,
                    .y_pixel = ws.y_pixel,
                }) catch {};
                return .{ .data = .{ .resize = {} } };
            },
            else => continue,
        }
    }
}
