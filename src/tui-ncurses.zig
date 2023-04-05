// Ncurses console backend for linux, requires a lot of dependencies
// see also https://github.com/ziglibs/ansi-term

const std = @import("std");
pub const c = @cImport({
    @cDefine("_XOPEN_SOURCE", "1");
    @cInclude("ncurses.h");
    @cInclude("unistd.h");
    @cInclude("locale.h");
});

pub const key = struct {
    pub usingnamespace c;
    pub const KEY_ESC = 27;
};

pub var COLS: u16 = 0;
pub var ROWS: u16 = 0;

// tree view
pub const stNormal = 1;
pub const stSelected = 2;
pub const stKey = 3;
pub const stValue = 4;
pub const stWilderness = 5;
pub const stScroll = 6;
pub const stScrollBk = 7;
// other
pub const stStatBar = 8;
pub const stSearch = 9;
pub const stMatchActive = 10;
pub const stMatchInactive = 11;
pub const stLoading = 12;
pub const stLoaded = 13;
pub const stHelp = 14;

var styles: [stHelp + 1]c_int = undefined;

pub var input: std.fs.File.Handle = undefined;
pub var output: std.fs.File.Handle = undefined;

var savedX: c_int = 0;
var savedY: c_int = 0;

pub fn init() !void {
    const tty = "/dev/tty";
    var ifile = c.fopen(tty, "r");
    var ofile = c.fopen(tty, "w");
    _ = c.setlocale(c.LC_ALL, "");
    input = c.fileno(ifile);
    output = c.fileno(ofile);
    if (c.newterm(null, ofile, ifile) == null)
        return error.NcursesInitFailed;

    updateSize();

    _ = c.cbreak();
    _ = c.noecho();
    //_=c.raw(); ctrl+c
    showCursor(false);
    _ = c.keypad(c.stdscr, true);
    _ = c.set_escdelay(25);
    // if (termType && (String_startsWith(termType, "xterm") || String_eq(termType, "vt220"))) {
    // https://github.com/htop-dev/htop/blob/2ca75625ee5c2ac0ef1571e6918d7c94f3aa011c/CRT.c#L956
    //       _=c.define_key("\x1b[1~OH", c.KEY_HOME);
    _ = c.start_color();
    _ = c.use_default_colors();
    // mvprintf(0, 2, "cs={}", .{c.COLORS});
    // _ = c.init_color(200, 0x1e * 1000 / 256, 0x77 * 1000 / 256, 0xd3 * 1000 / 256);
    // _ = c.init_pair(1, 200, c.COLOR_BLACK);
    // _ = c.attrset(c.COLOR_PAIR(1));
    // mvprint(0, 3, "asdadsada");
    // _ = c.getch();
    var BRIGHT: c_short = if (c.COLORS > 8) 8 else 0;
    initStyle(stNormal, c.COLOR_WHITE, c.COLOR_BLACK, 0);
    initStyle(stSelected, c.COLOR_BLACK, @intCast(c_short, c.COLOR_WHITE | BRIGHT), 0);
    initStyle(stKey, @intCast(c_short, c.COLOR_CYAN | BRIGHT), c.COLOR_BLACK, 0);
    initStyle(stValue, @intCast(c_short, c.COLOR_GREEN | BRIGHT), c.COLOR_BLACK, 0);
    initStyle(stWilderness, c.COLOR_BLUE, c.COLOR_BLACK, 0);
    initStyle(stScroll, @intCast(c_short, c.COLOR_WHITE | BRIGHT), c.COLOR_BLACK, 0);
    initStyle(stScrollBk, if (c.COLORS > 8) c.COLOR_WHITE else c.COLOR_BLACK, c.COLOR_BLACK, 0);
    //
    initStyle(stStatBar, c.COLOR_BLACK, c.COLOR_WHITE, 0);
    initStyle(stSearch, c.COLOR_WHITE, c.COLOR_BLACK, 0);
    initStyle(stMatchActive, c.COLOR_RED, c.COLOR_WHITE, 0);
    initStyle(stMatchInactive, c.COLOR_BLACK, c.COLOR_YELLOW, 0);
    initStyle(stLoading, c.COLOR_WHITE, c.COLOR_BLUE, 0);
    initStyle(stLoaded, c.COLOR_WHITE, @intCast(c_short, c.COLOR_BLUE | BRIGHT), 0);
    initStyle(stHelp, @intCast(c_short, c.COLOR_YELLOW | BRIGHT), c.COLOR_WHITE, 0);
}

pub fn deinit() void {
    _ = c.endwin();
}

pub fn showCursor(show: bool) void {
    // 0 	Invisible
    // 1 	Terminal-specific normal mode
    // 2 	Terminal-specific high visibility mode
    _ = c.curs_set(if (show) 1 else 0);
}

pub fn move(y: u16, x: u16) void {
    _ = c.move(y, x);
}

pub fn addnstr(text: []const u8) void {
    _ = c.addnstr(text.ptr, @intCast(c_int, text.len));
}

pub fn addnstrto(text: []const u8, right: u16) void {
    const cx = getcurx();
    if (right > cx)
        _ = c.addnstr(text.ptr, @intCast(c_int, @min(right - cx, text.len)));
}

pub fn mvhline(y: u16, x: u16, ch: u8, count: u16, newStyle: u16) void {
    //move(y, 0); _ = c.clrtoeol(); resets to default style
    style(newStyle);
    _ = c.mvhline(y, x, ch, count);
    move(y, x + count); // TODO: do I really need it?
}

pub const MouseInfo = struct { y: u16, x: u16, buttons: u16 };

pub const ControlKeys = struct {
    alt: bool = false,
    ctrl: bool = false,
    shift: bool = false,
};

pub const InputEvent = struct {
    data: union(enum) { char: u32, key: u16, resize: void, mouse: *MouseInfo },
    keys: ControlKeys = .{},
};

pub fn getch() InputEvent {
    while (true) {
        switch (c.getch()) {
            c.KEY_MIN...c.KEY_MAX => |ch| {
                if (ch == c.KEY_RESIZE) {
                    updateSize();
                    return .{ .data = .{ .resize = {} }, .keys = .{} };
                }
                return .{ .data = .{ .key = @intCast(u16, ch) }, .keys = .{} };
            },
            else => |ch| return .{ .data = .{ .char = @intCast(u32, ch) }, .keys = .{} },
        }
    }
}

pub fn getcurx() u16 {
    return @intCast(u16, c.getcurx(c.stdscr));
}

pub fn style(newStyle: u16) void {
    _ = c.attrset(styles[newStyle]);
    //_ = c.attr_set(c.A_UNDERLINE, @intCast(c_short, newStyle), null);
}

fn updateSize() void {
    ROWS = @intCast(u16, c.LINES);
    COLS = @intCast(u16, c.COLS);
}

fn initStyle(nStyle: u8, fg: c_short, bg: c_short, attr: c_int) void {
    _ = c.init_pair(nStyle, fg, bg);
    styles[nStyle] = c.COLOR_PAIR(nStyle) | attr;
}

pub fn refreshSize() void {
    _ = updateSize();
}

const myWriter = std.io.Writer(void, anyerror, struct {
    fn myWrite(self: void, bytes: []const u8) !usize {
        _ = self;
        addnstr(bytes);
        return bytes.len;
    }
}.myWrite){ .context = {} };

pub fn mvstyleprint(y: u16, x: u16, newStyle: u16, comptime fmt: []const u8, args: anytype) void {
    move(y, x);
    style(newStyle);
    std.fmt.format(myWriter, fmt, args) catch return;
    // TODO: use std.fmt.bufPrint();
}

pub fn saveCursor() void {
    savedX = c.getcurx(c.stdscr);
    savedY = c.getcurx(c.stdscr);
}

pub fn restoreCursor() void {
    _ = c.move(savedY, savedX);
}

pub fn refresh() void {
    _ = c.refresh();
}
