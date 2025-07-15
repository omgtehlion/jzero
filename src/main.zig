//  zig build -Drelease-fast
const std = @import("std");
const Allocator = std.mem.Allocator;
const Linenoise = @import("linenoise").Linenoise;
const tree = @import("./tree.zig");
//const tui = @import("./tui-win32.zig");
const tui = if (@import("builtin").target.os.tag == .windows) @import("./tui-win32.zig") else @import("./tui-ncurses.zig");
const ChunkedList = @import("./containers.zig").ChunkedList;
const search = @import("./search.zig");

var gpa: Allocator = undefined;

var ttyMutex: std.Thread.Mutex = .{};
// layout of tree view
const cursorMargin = 3;
const tvY = 0;
const tvBottom = 2;
// tree view state
var scrollY: u32 = 0;
var currentY: u32 = 0;
var scrollXPerNode: std.AutoHashMap(usize, u32) = undefined;
// ui state
var ephemeralInfo: ?[]const u8 = null;
var shortFileName: []const u8 = undefined;
var needToFocusActiveMatch = false;
var prevSelectedNode: ?*tree.Node = null;
// loading progress
var loadingWidth: u16 = 0;
var lastPct: usize = 0;
var lastUpdate: i64 = 0;
// file loading and parsing
var fileData: ChunkedList(u8, 512 * 1024) = undefined;
var parser = tree.json.StreamingParser.init();
var fileLen: ?usize = null;

fn killEphemeral() void {
    if (ephemeralInfo) |ei|
        gpa.free(ei);
    ephemeralInfo = null;
}

fn drawBreadcrumbs(node: *tree.Node, maxX: u16) void {
    var buf: [12]u8 = undefined;
    if (node.parent != tree.NO_ID) {
        drawBreadcrumbs(tree.at(node.parent), maxX);
        if (node.parent != tree.ROOT_ID and node.key != .int)
            tui.addnstrto(".", maxX);
        tui.addnstrto(formatKey(node, &buf), maxX);
    }
}

fn formatKey(node: *tree.Node, buf: []u8) []const u8 {
    return switch (node.key) {
        .str => |s| s,
        .int => |i| {
            if (node.level == 0)
                return "";
            buf[0] = if (node.level == 1) '$' else '[';
            const len = std.fmt.bufPrintIntToSlice(buf[1..], i, 10, .lower, .{}).len;
            if (node.level == 1) return buf[0 .. len + 1];
            buf[len + 1] = ']';
            return buf[0 .. len + 2];
        },
    };
}

fn drawPreview(node: *tree.Node, tvXX: u16, depthLeft: u16) void {
    switch (node.nType) {
        .literal => {
            printMatched(node.value, tui.stNormal, false, tvXX);
        },
        .obj => {
            if (depthLeft == 0) {
                tui.addnstrto("{…}", tvXX);
                return;
            }
            tui.addnstrto("{", tvXX);
            var ch = node.firstChild;
            while (ch != tree.NO_ID) {
                if (tui.getcurx() >= tvXX)
                    return;
                const child = tree.at(ch);
                printMatched(child.key.str, tui.stNormal, false, tvXX);
                tui.addnstrto(": ", tvXX);
                if (tui.getcurx() >= tvXX)
                    return;
                drawPreview(child, tvXX, depthLeft - 1);
                if (child.next != tree.NO_ID)
                    tui.addnstrto(", ", tvXX);
                ch = child.next;
            }
            tui.addnstrto("}", tvXX);
        },
        .array => {
            if (depthLeft == 0) {
                tui.addnstrto("[…]", tvXX);
                return;
            }
            tui.addnstrto("[", tvXX);
            var ch = node.firstChild;
            while (ch != tree.NO_ID) {
                if (tui.getcurx() >= tvXX)
                    return;
                const child = tree.at(ch);
                drawPreview(child, tvXX, depthLeft - 1);
                if (child.next != tree.NO_ID)
                    tui.addnstrto(", ", tvXX);
                ch = child.next;
            }
            tui.addnstrto("]", tvXX);
        },
    }
}

fn segBefore(a: []const u8, b: []const u8) []const u8 {
    const lenBefore = @intFromPtr(b.ptr) -| @intFromPtr(a.ptr);
    return a[0..lenBefore];
}

fn segAfter(a: []const u8, b: []const u8) []const u8 {
    const begin = @intFromPtr(b.ptr) + b.len -| @intFromPtr(a.ptr);
    return if (a.len > begin) a[begin..a.len] else a[a.len..a.len];
}

fn printMatched(str: []const u8, styleReturn: u16, selected: bool, tvXX: u16) void {
    var matchIter = search.iterator(str);
    var s = str;
    while (matchIter.next()) |match| {
        tui.addnstrto(segBefore(s, match), tvXX);
        var style: u16 = tui.stMatchInactive;
        if (selected) {
            if (search.currentMatch()) |cm| {
                if (match.ptr == cm.ptr) {
                    needToFocusActiveMatch = false;
                    style = tui.stMatchActive;
                }
            }
        }
        tui.style(style);
        tui.addnstrto(match, tvXX);
        tui.style(styleReturn);
        s = segAfter(str, match);
    }
    if (s.len > 0)
        tui.addnstrto(s, tvXX);
}

fn drawLine(node: *tree.Node, selected: bool, y: u16, tvXX: u16) void {
    tui.mvhline(y, 0, ' ', @min((node.level -| 1) * 2, tvXX), tui.stNormal);
    tui.style(if (selected) tui.stSelected else tui.stNormal);
    const arrow = if (node.firstChild != tree.NO_ID) (if (node.collapsed) "► " else "▼ ") else "  "; // ▸▾
    tui.addnstr(arrow);
    tui.style(if (selected) tui.stSelected else tui.stKey);
    switch (node.key) {
        .str => |s| {
            printMatched(s, if (selected) tui.stSelected else tui.stKey, selected, tvXX);
        },
        .int => |i| {
            if (node.level > 0) {
                var buf: [12]u8 = undefined;
                buf[0] = if (node.level == 1) '$' else '[';
                var len = std.fmt.bufPrintIntToSlice(buf[1..], i, 10, .lower, .{}).len;
                if (node.level != 1) {
                    buf[len + 1] = ']';
                    len += 1;
                }
                tui.addnstrto(buf[0 .. len + 1], tvXX);
            }
        },
    }
    tui.style(if (selected) tui.stSelected else tui.stNormal);
    tui.addnstrto(":", tvXX);
    if (selected) tui.style(tui.stNormal);
    tui.addnstrto(" ", tvXX);
    if (node.collapsed) {
        drawPreview(node, tvXX, 4);
    } else {
        switch (node.nType) {
            .literal => {},
            .obj => tui.addnstrto(if (node.firstChild == tree.NO_ID) "{}" else "{", tvXX),
            .array => tui.addnstrto(if (node.firstChild == tree.NO_ID) "[]" else "[", tvXX),
        }
    }
    if (node.value.len > 0) {
        tui.style(tui.stValue);
        var scrolled = @min(@as(usize, scrollXPerNode.get(@intFromPtr(node)) orelse 0), node.value.len - 1);
        if (needToFocusActiveMatch) {
            if (search.currentMatch()) |cm| {
                if (search.overlaps(cm, node.value)) {
                    // TODO: count real characters
                    const matchStart = @intFromPtr(cm.ptr) - @intFromPtr(node.value.ptr);
                    const matchEnd = matchStart + cm.len;
                    const offscreen = @as(isize, @intCast(matchEnd)) + tui.getcurx() - tvXX;
                    if (offscreen >= 0)
                        scrolled = @as(usize, @intCast(offscreen)) + 1;
                    if (matchStart < scrolled)
                        scrolled = matchStart;
                }
            }
        }
        if (scrolled > 0)
            tui.addnstrto("…", tvXX);
        printMatched(node.value[scrolled..], tui.stValue, selected, tvXX);
        if (tui.getcurx() >= tvXX)
            _ = scrollXPerNode.getOrPutValue(@intFromPtr(node), 0) catch {};
    }
}

fn redraw() void {
    ttyMutex.lock();
    defer ttyMutex.unlock();
    //breadcrumbsWidth =tui.COLS -| fnameMinWidth  @max();

    const tvYY = tui.ROWS - tvBottom;
    if (tvY >= tvYY)
        return;
    tui.saveCursor();

    var nn = tree.idAtY(scrollY);
    const height = tree.at(tree.ROOT_ID).height();
    const page = tvYY - tvY;
    const scrollVisible = height > page;
    const tvXX = tui.COLS - 2; //if (scrollVisible) tui.COLS - 1 else tui.COLS;
    const barH = @min(@max(1, (@as(u64, @intCast(page)) * (page) + height / 2) / height), page);
    const barY = if (scrollVisible) (@as(u64, @intCast(scrollY)) * (page - barH) + (height - page) / 2) / (height - page) else 0;
    const barYY = @min(barY + barH, page);

    var y: u16 = tvY;
    var selectedNode: ?*tree.Node = null;
    while (y < tvYY) : (y += 1) {
        const selected = y - tvY == currentY - scrollY;
        if (nn) |nodeId| {
            const node = tree.at(nodeId);
            if (selected)
                selectedNode = node;
            drawLine(node, selected, y, tvXX);
            nn = node.nextVisibleId();
        } else {
            tui.mvstyleprint(y, 0, tui.stWilderness, "~", .{});
        }
        const cx = tui.getcurx();
        if (tvXX >= cx)
            tui.mvhline(y, cx, ' ', tvXX + 1 - cx, tui.stNormal);
        if (scrollVisible) {
            tui.style(if (y < barY or y >= barYY) tui.stScrollBk else tui.stScroll);
            tui.addnstr("▐");
        } else {
            tui.addnstr(" ");
        }
    }

    tui.mvhline(tui.ROWS - 2, 0, ' ', tui.COLS, tui.stStatBar);
    tui.move(tui.ROWS - 2, 0);
    if (selectedNode) |node|
        drawBreadcrumbs(node, tui.COLS);
    tui.mvstyleprint(tui.ROWS - 2, tui.COLS - @as(u16, @intCast(std.unicode.utf8CountCodepoints(shortFileName) catch 0)), tui.stStatBar, "{s}", .{shortFileName});

    if (!search.prompt) {
        tui.mvhline(tui.ROWS - 1, 0, ' ', tui.COLS - loadingWidth, tui.stNormal);
        if (ephemeralInfo) |ei|
            tui.mvstyleprint(tui.ROWS - 1, 0, tui.stNormal, "{s}", .{ei});
    }

    if (selectedNode != prevSelectedNode)
        prevSelectedNode = selectedNode;

    tui.style(tui.stNormal);
    tui.restoreCursor();
    tui.refresh();
}

fn drawLoadingProgress() void {
    const w: u16 = 21;
    loadingWidth = w;
    ttyMutex.lock();
    defer ttyMutex.unlock();
    if (fileLen) |flen| {
        const pct = @max(1, @min(fileData.len * 100 / flen, 99));
        if (lastPct != pct) {
            const filled = @as(u16, @intCast(@max(1, w * pct / 100)));
            var msg: [w]u8 = [_]u8{' '} ** w;
            _ = std.fmt.bufPrint(&msg, "     Loading {}%", .{pct}) catch {}; // supports only ASCII
            tui.mvstyleprint(tui.ROWS - 1, tui.COLS - w, tui.stLoaded, "{s}", .{msg[0..filled]});
            tui.mvstyleprint(tui.ROWS - 1, tui.COLS - w + filled, tui.stLoading, "{s}", .{msg[filled..]});
            lastPct = pct;
        }
    } else {
        const now = std.time.milliTimestamp();
        if (now - lastUpdate >= 250) {
            var msg: [w]u8 = [_]u8{' '} ** w;
            _ = std.fmt.bufPrint(&msg, "Loaded {}kB", .{fileData.len / 1024}) catch {};
            tui.mvstyleprint(tui.ROWS - 1, tui.COLS - w, tui.stLoaded, "{s}", .{msg});
            lastUpdate = now;
        }
    }
    tui.refresh();
}

fn drawLoadingFinish(elapsedMs: i64) void {
    ttyMutex.lock();
    defer ttyMutex.unlock();
    const maxW = 256;
    var buff: [maxW]u8 = [_]u8{' '} ** maxW;
    const msg = std.fmt.bufPrint(&buff, "Loaded {}kB, {} nodes in {}ms", .{ fileData.len / 1024, tree.len(), elapsedMs }) catch "Done";
    const codepoints = std.unicode.utf8CountCodepoints(msg) catch msg.len;
    const width = @as(u16, @intCast(if (codepoints > tui.COLS) tui.COLS else codepoints));
    loadingWidth = width;
    tui.mvstyleprint(tui.ROWS - 1, tui.COLS - width, tui.stNormal, "{s}", .{msg});
    tui.refresh();
}

fn searchHints(allocator: Allocator, buf: []const u8) !?[]const u8 {
    _ = allocator;
    _ = buf;
    //re = Regex.compile(allocator, buf) catch return null;
    //defer re.deinit();
    //searchOnScreen(&re) catch return null;
    //redraw();
    ////tui.style(tui.stSearch);
    //tui.mvstyleprint(tui.ROWS - 1, 0, tui.stSearch, "", .{});
    //tui.refresh();
    return null;
}

fn findMatchedNode() ?*tree.Node {
    if (search.currentMatch()) |match| {
        var iter = tree.iterator();
        while (iter.next()) |node|
            if (search.overlapsNode(node, match))
                return node;
    }
    return null;
}

//⇧shift ⌃ctrl ⎇alt ⌥option ⌘command
const Help =
    \\  H, ⎇←        Focus the parent of the focused node, even if it is an
    \\               expanded object or array
    \\  J, ⎇↓        Move to the focused node's next     sibling
    \\  K, ⎇↑        Move to the focused node's previous sibling
    \\  c            Collapse the focused node and all its siblings
    \\  e            Expand   the focused node and all its siblings
    \\
    \\  ^e           Scroll down one line
    \\  ^y           Scroll up   one line
    \\  .            Scroll value right
    \\  ,            Scroll value left
    \\
    \\  /            Start a search
    \\  n            Next match
    \\  N            Previous match
;

fn showHelp() void {
    var iter = std.mem.splitScalar(u8, Help, '\n');
    var i: u16 = 0;
    while (iter.next()) |line| {
        tui.mvstyleprint(i, 2, tui.stHelp, "{s:<80}", .{line});
        i += 1;
    }
    tui.refresh();
    _ = tui.getch();
}

fn readAndParseChunk(file: std.fs.File) !bool {
    var slice = try fileData.getSlice(1024);
    const read = try file.reader().read(slice.fresh());

    var pos: usize = slice.offset;
    for (slice.fresh()[0..read]) |c| {
        var token1: ?tree.json.Token = undefined;
        var token2: ?tree.json.Token = undefined;
        try parser.feed(c, &token1, &token2);
        pos += 1;
        if (token1) |t1| {
            try tree.loader.load(slice.fromStart(pos), pos, t1);
            //std.time.sleep(1e6);
            if (token2) |t2|
                try tree.loader.load(slice.fromStart(pos), pos, t2);
        }
    }
    // check for data split between chunks:
    const unread = if (read == slice.fresh().len) switch (parser.state) {
        .Identifier, .Number, .NumberMaybeDotOrExponent, .NumberMaybeDigitOrDotOrExponent, .NumberFractionalRequired, .NumberFractional => parser.count + 1,
        .NumberMaybeExponent, .NumberExponent, .NumberExponentDigitsRequired, .NumberExponentDigits => parser.count + 1,
        .String, .StringUtf8Byte2Of2, .StringUtf8Byte2Of3, .StringUtf8Byte3Of3, .StringUtf8Byte2Of4, .StringUtf8Byte3Of4, .StringUtf8Byte4Of4 => parser.count + 1,
        .StringEscapeCharacter, .StringEscapeHexUnicode4, .StringEscapeHexUnicode3, .StringEscapeHexUnicode2, .StringEscapeHexUnicode1 => parser.count + 1,
        else => 0,
    } else 0;
    if (unread > 0) {
        try fileData.commit(read - unread);
        var newSlice = try fileData.getSlice(unread + 1); // this will force new chunk allocation
        std.mem.copyForwards(u8, newSlice.fresh(), slice.fresh()[(read - unread)..]);
        try fileData.commit(unread);
    } else {
        try fileData.commit(read);
    }
    // TODO: wait for more input
    if (read == 0) { //if (read != slice.fresh().len) {
        return false; //std.time.sleep(1e9);
    }
    return true;
}

fn loadingThread(file: std.fs.File) !void {
    const start = std.time.milliTimestamp();
    while (try readAndParseChunk(file))
        drawLoadingProgress();
    drawLoadingFinish(std.time.milliTimestamp() - start);
}

fn key_ctrl(comptime c: u8) u8 {
    return c - '`';
}

pub fn main() !void {
    //@compileLog(@sizeOf(tree.Node));
    var GPA = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = GPA.deinit();
    gpa = GPA.allocator();

    search.init(gpa);
    defer search.deinit();

    scrollXPerNode = @TypeOf(scrollXPerNode).init(gpa);
    defer scrollXPerNode.deinit();

    var args = try std.process.argsWithAllocator(gpa);
    defer args.deinit();
    _ = args.next();
    var file = if (std.io.getStdIn().isTty()) _: {
        const fileName = args.next() orelse {
            std.debug.print("File name required\n", .{});
            return;
        };
        var quoted = try gpa.alloc(u8, fileName.len + 2);
        quoted[0] = '"';
        std.mem.copyForwards(u8, quoted[1..], fileName);
        quoted[quoted.len - 1] = '"';
        ephemeralInfo = quoted;
        shortFileName = std.fs.path.basename(fileName);
        const file = try std.fs.cwd().openFile(fileName, .{});
        fileLen = @intCast(try file.getEndPos());
        break :_ file;
    } else _: {
        ephemeralInfo = try gpa.dupe(u8, "Reading from standard input");
        shortFileName = "(STDIN)";
        break :_ std.io.getStdIn();
    };
    defer killEphemeral();
    defer file.close();
    fileData = @TypeOf(fileData).init(std.heap.page_allocator);
    defer fileData.deinit();
    try tree.loader.init();

    try tui.init();
    defer tui.deinit();
    tui.showCursor(false);
    if (try readAndParseChunk(file)) {
        const thread = try std.Thread.spawn(.{}, loadingThread, .{file});
        thread.setName("loading thread") catch {};
        thread.detach();
    }
    redraw();

    var ln = Linenoise.initWithFiles(gpa, .{ .handle = tui.input }, .{ .handle = tui.output });
    ln.print_newline = false;
    defer ln.deinit();
    //ln.history.load("history.txt") catch {}; defer ln.history.save("history.txt") catch {};
    ln.hints_callback = searchHints;

    const key = tui.key;
    var lastButtons: u32 = 0;
    while (true) {
        const PAGE = @max(tui.ROWS, tvY + tvBottom + 1) - tvY - tvBottom - 1;
        var evt = tui.getch();
        //std.debug.print("{}\r\n", .{evt});
        // patch some key aliases
        if (evt.keys.alt) {
            evt = switch (evt.data) {
                .key => |k| switch (k) {
                    key.KEY_UP => .{ .data = .{ .char = 'K' } },
                    key.KEY_DOWN => .{ .data = .{ .char = 'J' } },
                    key.KEY_LEFT => .{ .data = .{ .char = 'H' } },
                    else => evt,
                },
                else => evt,
            };
        } else {
            evt = switch (evt.data) {
                .key => |k| switch (k) {
                    key.KEY_UP => .{ .data = .{ .char = 'k' } },
                    key.KEY_DOWN => .{ .data = .{ .char = 'j' } },
                    key.KEY_LEFT => .{ .data = .{ .char = 'h' } },
                    key.KEY_RIGHT => .{ .data = .{ .char = 'l' } },
                    else => evt,
                },
                else => evt,
            };
        }
        var lineDelta: i64 = 0;
        switch (evt.data) {
            .key => |k| switch (k) {
                key.KEY_PPAGE => lineDelta = -@as(i32, @intCast(PAGE)),
                key.KEY_NPAGE => lineDelta = PAGE,
                key.KEY_ESC => break,
                key.KEY_HOME => currentY = 0,
                key.KEY_END => currentY = tree.height() - 1,
                key.KEY_F(1) => showHelp(),
                else => continue,
            },
            .char => |c| switch (c) {
                key_ctrl('e') => {
                    scrollY = @min(scrollY + 1, tree.height() - PAGE);
                    currentY = @max(currentY, scrollY + cursorMargin);
                },
                key_ctrl('y') => {
                    scrollY = @max(scrollY, 1) - 1;
                    currentY = @min(currentY, scrollY + PAGE - cursorMargin);
                },
                'q' => break,
                '/' => {
                    search.prompt = true;
                    killEphemeral();
                    tui.mvstyleprint(tui.ROWS - 1, 0, tui.stSearch, "", .{});
                    tui.showCursor(true);
                    tui.refresh();
                    if (try ln.linenoise("/")) |input| {
                        defer ln.allocator.free(input);
                        if (input.len == 0) {
                            search.nextMatch(.Forward, prevSelectedNode);
                        } else {
                            try ln.history.add(input);
                            try search.start(input, &fileData);
                        }
                        if (findMatchedNode()) |node| {
                            node.expandParentToThis();
                            needToFocusActiveMatch = true;
                            currentY = node.y();
                        } else {
                            ephemeralInfo = try gpa.dupe(u8, "Not found");
                        }
                    }
                    tui.refreshSize();
                    tui.showCursor(false);
                    search.prompt = false;
                },
                // next / prev match
                'n', 'N' => {
                    search.nextMatch(if (c == 'N') .Back else .Forward, prevSelectedNode);
                    if (findMatchedNode()) |node| {
                        node.expandParentToThis();
                        needToFocusActiveMatch = true;
                        currentY = node.y();
                    }
                },
                'k' => lineDelta = -1,
                'j' => lineDelta = 1,
                'h' => if (tree.atY(currentY)) |node| {
                    if (!node.collapse(true) and node.parent != tree.ROOT_ID)
                        currentY = tree.at(node.parent).y();
                },
                'l' => if (tree.atY(currentY)) |node| {
                    if (!node.collapse(false) and node.firstChild != tree.NO_ID)
                        currentY += 1;
                },
                'K' => if (tree.atY(currentY)) |node| {
                    const prevId = node.prevId(null);
                    if (prevId != tree.NO_ID)
                        currentY = tree.at(prevId).y();
                },
                'J' => if (tree.atY(currentY)) |node| {
                    if (node.next != tree.NO_ID)
                        currentY = tree.at(node.next).y();
                },
                'H' => if (tree.atY(currentY)) |node| {
                    if (node.parent != tree.ROOT_ID)
                        currentY = tree.at(node.parent).y();
                },
                // collapse / expand this level
                'c', 'e' => if (tree.atY(currentY)) |node| {
                    const prevCurrentY = currentY;
                    var ch = tree.at(node.parent).firstChild;
                    while (ch != tree.NO_ID) : (ch = tree.at(ch).next)
                        _ = tree.at(ch).collapse(c == 'c');
                    currentY = node.y();
                    scrollY = @intCast(@max(0, @as(i64, @intCast(scrollY)) + currentY - prevCurrentY));
                },
                // scroll left / right
                ',', '.' => if (tree.atY(currentY)) |node| {
                    if (scrollXPerNode.get(@intFromPtr(node))) |scrollX| {
                        const newScroll = if (c == ',') scrollX -| 1 else scrollX +| 1;
                        scrollXPerNode.put(@intFromPtr(node), newScroll) catch {};
                    }
                },
                else => continue,
            },
            .mouse => |mouse| {
                // MOUSE_WHEEL not supported on windows
                if (mouse.buttons & 0x01 != 0 and lastButtons & 0x01 == 0) { // left click
                    if (mouse.y >= tvY and mouse.y < tui.ROWS - tvBottom and mouse.x < tui.COLS - 1) {
                        const line = scrollY + mouse.y;
                        if (tree.atY(line)) |node| {
                            const arrowX = (node.level -| 1) * 2;
                            if (mouse.x >= arrowX -| 1 and mouse.x < arrowX + 2) // TODO: or double click
                                _ = node.collapse(!node.collapsed);
                            currentY = line;
                        }
                    }
                }
                lastButtons = mouse.buttons;
            },
            .resize => {},
        }
        currentY = @intCast(@max(0, @min(lineDelta + currentY, tree.height() - 1)));
        scrollY = if (currentY < scrollY + cursorMargin) currentY -| cursorMargin else if (currentY > scrollY + (PAGE - cursorMargin)) currentY - (PAGE - cursorMargin) else scrollY;
        redraw();
    }
}
