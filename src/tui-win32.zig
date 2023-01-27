// Native win32 console backend for pre-Windows10 conhost
// TODO: use https://learn.microsoft.com/en-us/windows/console/console-virtual-terminal-sequences
// see also https://github.com/ziglibs/zig-windows-console

const std = @import("std");
const unicode = std.unicode;
const toWtf16 = unicode.utf8ToUtf16LeStringLiteral;
const wcwidth = @import("wcwidth").wcwidth;

const w = struct {
    pub usingnamespace std.os.windows;
    pub const CONSOLE_TEXTMODE_BUFFER = @as(c_int, 1);
    pub const ENABLE_LINE_INPUT = @as(c_int, 0x2);
    pub const ENABLE_ECHO_INPUT = @as(c_int, 0x4);
    pub const ENABLE_WINDOW_INPUT = @as(c_int, 0x8);
    pub const ENABLE_MOUSE_INPUT = @as(c_int, 0x10);
    pub const ENABLE_WRAP_AT_EOL_OUTPUT = @as(c_int, 0x2);
    pub const ENABLE_VIRTUAL_TERMINAL_PROCESSING = @as(c_int, 0x4);
    pub const DISABLE_NEWLINE_AUTO_RETURN = @as(c_int, 0x8);
    pub const ENABLE_QUICK_EDIT_MODE = @as(c_int, 0x40);
    pub const ENABLE_EXTENDED_FLAGS = @as(c_int, 0x80);
    pub const CP_UTF8 = @as(c_int, 65001);
    pub const KEY_EVENT_RECORD = extern struct {
        bKeyDown: w.BOOL,
        wRepeatCount: w.WORD,
        wVirtualKeyCode: w.WORD,
        wVirtualScanCode: w.WORD,
        uChar: extern union {
            UnicodeChar: w.WCHAR,
            AsciiChar: w.CHAR,
        },
        dwControlKeyState: w.DWORD,
    };
    pub const MOUSE_EVENT_RECORD = extern struct {
        dwMousePosition: w.COORD,
        dwButtonState: w.DWORD,
        dwControlKeyState: w.DWORD,
        dwEventFlags: w.DWORD,
    };
    pub const WINDOW_BUFFER_SIZE_RECORD = w.COORD;
    pub const MENU_EVENT_RECORD = w.UINT;
    pub const FOCUS_EVENT_RECORD = w.BOOL;
    pub const INPUT_RECORD = extern struct {
        EventType: w.WORD,
        Event: extern union {
            KeyEvent: KEY_EVENT_RECORD,
            MouseEvent: MOUSE_EVENT_RECORD,
            WindowBufferSizeEvent: WINDOW_BUFFER_SIZE_RECORD,
            MenuEvent: MENU_EVENT_RECORD,
            FocusEvent: FOCUS_EVENT_RECORD,
        },
    };
    pub const KEY_EVENT = @as(c_int, 0x1);
    pub const MOUSE_EVENT = @as(c_int, 0x2);
    pub const WINDOW_BUFFER_SIZE_EVENT = @as(c_int, 0x4);
    pub const MENU_EVENT = @as(c_int, 0x8);
    pub const FOCUS_EVENT = @as(c_int, 0x10);
    pub const VK_MENU = @as(c_int, 0x12);
    pub const CONSOLE_CURSOR_INFO = extern struct {
        dwSize: w.DWORD,
        bVisible: w.BOOL,
    };
    pub const ICON_SMALL = @as(c_int, 0);
    pub const ICON_BIG = @as(c_int, 1);
};

const k32 = struct {
    pub usingnamespace std.os.windows.kernel32;
    pub extern "kernel32" fn GetConsoleCursorInfo(hConsoleOutput: w.HANDLE, lpConsoleCursorInfo: *w.CONSOLE_CURSOR_INFO) callconv(w.WINAPI) w.BOOL;
    pub extern "kernel32" fn SetConsoleCursorInfo(hConsoleOutput: w.HANDLE, lpConsoleCursorInfo: *const w.CONSOLE_CURSOR_INFO) callconv(w.WINAPI) w.BOOL;
    pub extern "kernel32" fn WriteConsoleA(hConsoleOutput: w.HANDLE, lpBuffer: [*]const u8, nNumberOfCharsToWrite: w.DWORD, lpNumberOfCharsWritten: ?*w.DWORD, lpReserved: ?*anyopaque) callconv(w.WINAPI) w.BOOL;
    pub extern "kernel32" fn CreateConsoleScreenBuffer(dwDesiredAccess: w.DWORD, dwShareMode: w.DWORD, lpSecurityAttributes: ?*anyopaque, dwFlags: w.DWORD, lpScreenBufferData: ?w.LPVOID) callconv(w.WINAPI) w.HANDLE;
    pub extern "kernel32" fn SetConsoleScreenBufferSize(hConsoleOutput: w.HANDLE, dwSize: w.COORD) callconv(w.WINAPI) w.BOOL;
    pub extern "kernel32" fn SetConsoleActiveScreenBuffer(hConsoleOutput: w.HANDLE) callconv(w.WINAPI) w.BOOL;
    pub extern "kernel32" fn SetConsoleMode(hConsoleHandle: w.HANDLE, dwMode: w.DWORD) callconv(w.WINAPI) w.BOOL;
    pub extern "kernel32" fn SetConsoleCP(wCodePageID: w.UINT) callconv(w.WINAPI) w.BOOL;
    pub extern "kernel32" fn ReadConsoleInputW(hConsoleInput: w.HANDLE, lpBuffer: [*]w.INPUT_RECORD, nLength: w.DWORD, lpNumberOfEventsRead: ?*w.DWORD) callconv(w.WINAPI) w.BOOL;
    pub extern "kernel32" fn GetConsoleWindow() callconv(w.WINAPI) w.HWND;
    pub extern "kernel32" fn SendMessageW(hWnd: w.HWND, Msg: w.UINT, wParam: w.WPARAM, lParam: w.LPARAM) callconv(w.WINAPI) w.LRESULT;
};

const user32 = struct {
    pub usingnamespace std.os.windows.user32;
    pub extern "user32" fn LoadIconW(hInstance: w.HMODULE, lpIconName: [*:0]const u16) callconv(w.WINAPI) w.LPARAM;
};

pub const key = struct {
    pub const KEY_UP = 72;
    pub const KEY_DOWN = 80;
    pub const KEY_PPAGE = 73;
    pub const KEY_NPAGE = 81;
    pub const KEY_ESC = 1;
    pub const KEY_LEFT = 75;
    pub const KEY_RIGHT = 77;
    pub const KEY_HOME = 71;
    pub const KEY_END = 79;
    pub const KEY_ENTER = 28;
};

pub var COLS: u16 = 0;
pub var ROWS: u16 = 0;

// tree view
pub const stNormal = 0x07;
pub const stSelected = 0xF0;
pub const stKey = 0x0B;
pub const stValue = 0x0A;
pub const stWilderness = 0x09;
pub const stScroll = 0x0F;
pub const stScrollBk = 0x08;
// other
pub const stStatBar = 0x70;
pub const stSearch = 0x0F;
pub const stFound = 0x74;
pub const stLoading = 0x17;
pub const stLoaded = 0x97;

pub var input = w.INVALID_HANDLE_VALUE;
pub var output = w.INVALID_HANDLE_VALUE;
var startupOutput = w.INVALID_HANDLE_VALUE;
var csbi: w.CONSOLE_SCREEN_BUFFER_INFO = undefined;
var lastMouse: MouseInfo = .{ .y = 0, .x = 0, .buttons = 0 };
var currentCursor: w.CONSOLE_CURSOR_INFO = undefined;
var savedCursor: w.CONSOLE_CURSOR_INFO = undefined;
var savedCursorPos: w.COORD = undefined;
var prevInputMode: w.DWORD = undefined;
var prevOutputMode: w.DWORD = undefined;
var prevIcon: [2]w.DWORD = undefined;
var lastCursorX: u16 = 0;

pub fn init() !void {
    // fun part: set console window icon
    var ico = user32.LoadIconW(k32.GetModuleHandleW(null).?, comptime toWtf16("MAINICON"));
    // k32.SetConsoleIcon(ico) is deprecated, use messages
    const wnd = k32.GetConsoleWindow();
    _ = k32.SendMessageW(wnd, user32.WM_GETICON, w.ICON_SMALL, @intCast(isize, @ptrToInt(&prevIcon[0])));
    _ = k32.SendMessageW(wnd, user32.WM_GETICON, w.ICON_BIG, @intCast(isize, @ptrToInt(&prevIcon[1])));
    _ = k32.SendMessageW(wnd, user32.WM_SETICON, w.ICON_SMALL, ico); // ICON_SMALL
    _ = k32.SendMessageW(wnd, user32.WM_SETICON, w.ICON_BIG, ico); // ICON_BIG

    // create a new screen, and reopen real TTY because sometimes we use stdin to read data
    const SHARE_RW = w.FILE_SHARE_READ | w.FILE_SHARE_WRITE;
    startupOutput = k32.GetStdHandle(w.STD_OUTPUT_HANDLE).?;
    output = k32.CreateConsoleScreenBuffer(w.GENERIC_READ | w.GENERIC_WRITE, SHARE_RW, null, w.CONSOLE_TEXTMODE_BUFFER, null);
    _ = k32.GetConsoleScreenBufferInfo(startupOutput, &csbi);
    _ = updateSize(false);
    _ = k32.SetConsoleActiveScreenBuffer(output);
    input = k32.CreateFileW(comptime toWtf16("\\\\.\\CONIN$"), w.GENERIC_READ | w.GENERIC_WRITE, SHARE_RW, null, w.OPEN_EXISTING, w.FILE_ATTRIBUTE_NORMAL, null);

    // configure console modes and codepage
    {
        _ = k32.GetConsoleMode(input, &prevInputMode);
        var consoleMode = prevInputMode | w.ENABLE_WINDOW_INPUT; // Report changes in buffer size
        consoleMode |= w.ENABLE_MOUSE_INPUT;
        //consoleMode &= ~ENABLE_PROCESSED_INPUT; // Report CTRL+C and SHIFT+Arrow events.
        consoleMode |= w.ENABLE_EXTENDED_FLAGS; // Disable the Quick Edit mode,
        consoleMode &= @bitCast(w.DWORD, ~w.ENABLE_QUICK_EDIT_MODE); // which inhibits the mouse.
        _ = k32.SetConsoleMode(input, consoleMode);
    }
    {
        _ = k32.GetConsoleMode(output, &prevOutputMode);
        var consoleMode = prevOutputMode & @bitCast(w.DWORD, ~w.ENABLE_WRAP_AT_EOL_OUTPUT); // Avoid scrolling when reaching end of line.
        //_ = k32.SetConsoleMode(output, consoleMode);
        // Try enabling VT sequences.
        consoleMode |= w.DISABLE_NEWLINE_AUTO_RETURN; // Do not do CR on LF.
        //consoleMode |= w.ENABLE_VIRTUAL_TERMINAL_PROCESSING; // Allow ANSI escape sequences.
        _ = k32.SetConsoleMode(output, consoleMode);
        //_ = k32.GetConsoleMode(output, &consoleMode);
        //const supportsVT = consoleMode & w.ENABLE_VIRTUAL_TERMINAL_PROCESSING;
    }
    _ = k32.SetConsoleCP(w.CP_UTF8);
    _ = k32.SetConsoleOutputCP(w.CP_UTF8);
    // see also https://github.com/madsen/vbindiff/blob/7e056184c0e1e687df028c6d5fb36a6efb63adf5/win32/ConWin.cpp
    // and https://github.com/flagxor/rainbowforth/blob/32610920596dfefeaa129f94454a7423c0efb60e/rainbowforth/native/console.c
    // and https://www.installsetupconfig.com/win32programming/winconsolecharapplication8_7.html
    //     auto &display = supportsVT ? *new AnsiDisplay<Win32Display>(io) : *new Win32Display(io);
}

pub fn deinit() void {
    _ = k32.SetConsoleMode(input, prevInputMode);
    _ = k32.SetConsoleMode(startupOutput, prevOutputMode);
    const wnd = k32.GetConsoleWindow();
    _ = k32.SendMessageW(wnd, user32.WM_SETICON, w.ICON_SMALL, prevIcon[0]);
    _ = k32.SendMessageW(wnd, user32.WM_SETICON, w.ICON_BIG, prevIcon[1]);
}

pub fn showCursor(show: bool) void {
    currentCursor = w.CONSOLE_CURSOR_INFO{ .dwSize = 1, .bVisible = if (show) 1 else 0 };
    _ = k32.SetConsoleCursorInfo(output, &currentCursor);
}

pub fn saveCursor() void {
    _ = k32.GetConsoleCursorInfo(output, &savedCursor);
    _ = k32.GetConsoleScreenBufferInfo(output, &csbi);
    savedCursorPos = csbi.dwCursorPosition;
    lastCursorX = @intCast(u16, savedCursorPos.X);
}

pub fn restoreCursor() void {
    _ = k32.SetConsoleCursorPosition(output, savedCursorPos);
    _ = k32.SetConsoleCursorInfo(output, &savedCursor);
    lastCursorX = @intCast(u16, savedCursorPos.X);
}

pub fn move(y: u16, x: u16) void {
    _ = k32.SetConsoleCursorPosition(output, .{ .X = @intCast(i16, x), .Y = @intCast(i16, y) });
    lastCursorX = x;
}

pub fn addnstr(text: []const u8) void {
    var ignored: w.DWORD = 0;
    _ = k32.WriteConsoleA(output, text.ptr, @intCast(w.DWORD, text.len), &ignored, null);
    lastCursorX += @intCast(u16, unicode.utf8CountCodepoints(text) catch 0);
}

pub fn addnstrto(text: []const u8, right: u16) void {
    const cx = getcurx();
    if (cx >= right)
        return;
    const maxLen = right - cx;
    var ignored: w.DWORD = 0;
    var len: isize = 0;
    var i: u32 = 0;
    // TODO: test this in unit-test
    while (i < text.len and len <= maxLen) {
        const n = unicode.utf8ByteSequenceLength(text[i]) catch return; // TODO: return or throw an error
        if (i + n > text.len) return;
        const ch = unicode.utf8Decode(text[i..][0..n]) catch '?';
        i += n;
        len += @max(0, wcwidth(ch)); // HACK: ignore unprintable
    }
    _ = k32.WriteConsoleA(output, text.ptr, @intCast(w.DWORD, i), &ignored, null);
    lastCursorX += @intCast(u16, len);
}

pub fn mvhline(y: u16, x: u16, ch: u8, count: u16, newStyle: u16) void {
    //console.console_clear();
    var ignored: w.DWORD = 0;
    const coord = w.COORD{ .X = @intCast(i16, x), .Y = @intCast(i16, y) };
    _ = k32.FillConsoleOutputAttribute(output, newStyle, count, coord, &ignored);
    _ = k32.FillConsoleOutputCharacterW(output, ch, count, coord, &ignored);
    move(y, x + count); // TODO: do I really need it?
    style(newStyle);
}

pub const ControlKeys = struct {
    alt: bool = false,
    ctrl: bool = false,
    shift: bool = false,
    pub fn parse(val: w.DWORD) ControlKeys {
        // https://learn.microsoft.com/en-us/windows/console/key-event-record-str
        return .{
            .alt = val & (0x0002 | 0x0001) != 0,
            .ctrl = val & (0x0008 | 0x0004) != 0,
            .shift = val & 0x0010 != 0,
        };
    }
};

pub const MouseInfo = struct { y: u16, x: u16, buttons: u16 };

pub const InputEvent = struct {
    data: union(enum) { char: u32, key: u16, resize: void, mouse: MouseInfo },
    keys: ControlKeys,
};

pub fn getch() InputEvent {
    var ir: [1]w.INPUT_RECORD = undefined;
    var ok: w.DWORD = 0;
    while (true) {
        while (k32.ReadConsoleInputW(input, &ir, 1, &ok) == 0 or ok == 0) {}
        switch (ir[0].EventType) {
            w.KEY_EVENT => {
                // see https://github.com/green9016/video-player-ext/blob/a7b4ffea514ee3a1555dce92784529fff30d5bb8/contrib/win32/caca/caca/driver/win32.c#L252
                const ke = ir[0].Event.KeyEvent;
                const uc = ke.uChar.UnicodeChar;
                //mvprintf(0, ROWS - 1, "ke={} char={} vk={} u16, msc={}          ", .{ ke.bKeyDown, uc, ke.wVirtualKeyCode, ke.wVirtualScanCode });
                if (ke.bKeyDown != 0 or (ke.wVirtualKeyCode == w.VK_MENU and uc != 0)) {
                    return switch (uc) {
                        // send backsp, tab, ctrl+enter, enter, esc as keys
                        0, 8, 9, 10, 13, 27 => .{ .data = .{ .key = ke.wVirtualScanCode }, .keys = ControlKeys.parse(ke.dwControlKeyState) },
                        else => .{ .data = .{ .char = uc }, .keys = ControlKeys.parse(ke.dwControlKeyState) },
                    };
                }
            },
            w.WINDOW_BUFFER_SIZE_EVENT => {
                if (updateSize(true))
                    return .{ .data = .{ .resize = {} }, .keys = .{} };
                continue;
            },
            w.MOUSE_EVENT => {
                const me = ir[0].Event.MouseEvent;
                //std.debug.print("MouseEvent {} {} {} {}\r\n", .{me.dwButtonState, me.dwEventFlags, me.dwMousePosition.X, me.dwMousePosition.Y});
                if (me.dwButtonState != lastMouse.buttons) {
                    lastMouse = .{ .y = @intCast(u16, me.dwMousePosition.Y), .x = @intCast(u16, me.dwMousePosition.X), .buttons = @intCast(u16, me.dwButtonState) };
                    return .{ .data = .{ .mouse = lastMouse }, .keys = ControlKeys.parse(me.dwControlKeyState) };
                }
                continue;
            },
            else => {},
        }
    }
}

pub fn getcurx() u16 {
    //_ = k32.GetConsoleScreenBufferInfo(output, &csbi);
    //return @intCast(u16, csbi.dwCursorPosition.X);
    return lastCursorX;
}

pub fn style(newStyle: u16) void {
    _ = k32.SetConsoleTextAttribute(output, newStyle);
}

fn updateSize(updating: bool) bool {
    //https://github.com/magiblot/tvision/blob/a0f449dfdff018cf809ba364d309c30d479f3651/source/platform/win32con.cpp#L188
    if (updating)
        _ = k32.GetConsoleScreenBufferInfo(output, &csbi);
    const newSz = w.COORD{ .X = @max(csbi.srWindow.Right - csbi.srWindow.Left, 0) + 1, .Y = @max(csbi.srWindow.Bottom - csbi.srWindow.Top, 0) + 1 };
    if (newSz.X != COLS or newSz.Y != ROWS) {
        COLS = @intCast(u16, newSz.X);
        ROWS = @intCast(u16, newSz.Y);
        _ = k32.SetConsoleCursorPosition(output, .{ .X = 0, .Y = 0 });
        _ = k32.SetConsoleScreenBufferSize(output, newSz);
        _ = k32.SetConsoleCursorPosition(output, csbi.dwCursorPosition);
        _ = k32.SetConsoleCursorInfo(output, &currentCursor);
        return true;
    }
    return false;
}

pub fn refreshSize() void {
    _ = updateSize(true);
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

pub fn refresh() void {}
