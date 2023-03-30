const std = @import("std");
const Allocator = std.mem.Allocator;
//const Regex = @import("zig-regex").Regex; //https://github.com/tiehuis/zig-regex
// see also https://github.com/ziglibs/string-searching
const ChunkedList = @import("./containers.zig").ChunkedList;

//const Span = struct { start: u32, end: u32 };
//var keyfound: AutoHashMap(u32, Span) = undefined;
//var valfound: AutoHashMap(u32, Span) = undefined;
//var re: Regex = undefined;
var allocator: Allocator = undefined;
var allMatches: std.ArrayList([]const u8) = undefined;
var currentMatchId: usize = 0;

pub var prompt = false;

pub fn init(alloc: Allocator) void {
    allocator = alloc;
    allMatches = @TypeOf(allMatches).init(alloc);
}

pub fn deinit() void {
    allMatches.deinit();
}

pub fn start(q: []const u8, data: *ChunkedList(u8, 512 * 1024)) !void {
    allMatches.clearAndFree();
    //re = try Regex.compile(allocator, q);
    //defer re.deinit();
    for (data.chunks.items) |chunk| {
        var str = chunk;
        //while (try re.captures(str)) |cap| {
        //    defer cap.deinit();
        //    const begin = @intCast(u32, cap.slots[0].?);
        //    const end = @intCast(u32, cap.slots[1].?);
        //    try allMatches.append(str[begin..end]);
        //    str = str[end..];
        //    //break; // TODO: find all entries
        //}
        // TODO: use string find
        while (str.len >= q.len) {
            if (std.mem.indexOf(u8, str, q)) |begin| {
                const end = begin + q.len;
                try allMatches.append(str[begin..end]);
                str = str[end..];
            } else {
                break;
            }
        }
    }
}

pub fn nextMatch() void {
    currentMatchId = if (allMatches.items.len > 0) (currentMatchId + 1) % allMatches.items.len else 0;
}

pub fn currentMatch() ?[]const u8 {
    if (currentMatchId >= 0 and currentMatchId < allMatches.items.len)
        return allMatches.items[currentMatchId];
    return null;
}

pub fn overlaps(a: []const u8, b: []const u8) bool {
    const ap = @ptrToInt(a.ptr);
    const bp = @ptrToInt(b.ptr);
    return ap < bp + b.len and bp < ap + a.len;
}

pub const Iterator = struct {
    index: usize,
    str: []const u8,
    pub fn next(it: *Iterator) ?[]const u8 {
        if (it.index >= allMatches.items.len)
            return null;
        var match = allMatches.items[it.index];
        it.index += 1;
        if (!overlaps(match, it.str)) {
            it.index = allMatches.items.len;
            return null;
        }
        return match;
    }
    // pub fn peek(it: *Iterator) ?[]const u8 {
    //     _ = it;
    //     return null;
    // }
};

pub fn iterator(s: []const u8) Iterator {
    for (allMatches.items) |match, idx|
        if (overlaps(s, match))
            return .{ .index = idx, .str = s };
    return .{ .index = allMatches.items.len, .str = s };
}

pub fn matches(s: []const u8) ?[3][]const u8 {
    for (allMatches.items) |match| {
        const sp = @ptrToInt(s.ptr);
        const mp = @ptrToInt(match.ptr);
        if (overlaps(s, match)) {
            const begin = mp -| sp;
            const end = s.len - ((sp + s.len) -| (mp + match.len));
            return .{ s[0..begin], s[begin..end], s[end..] };
        }
    }
    return null;
}

//pub fn hints(allocator: Allocator, buf: []const u8) !?[]const u8 {
//    re = Regex.compile(allocator, buf) catch return null;
//    defer re.deinit();
//    searchOnScreen(&re) catch return null;
//    redraw();
//    //tui.style(tui.stSearch);
//    tui.mvstyleprint(tui.ROWS - 1, 0, tui.stSearch, "", .{});
//    tui.refresh();
//    return null;
//}

//fn searchOnScreen(rx: *Regex) !void {
//    const tvYY = 30;//tui.ROWS - tvBottom;
//    //keyfound.clearAndFree();
//    //valfound.clearAndFree();
//    var nn = tree.idAtY(scrollY);
//    var y: u16 = tvY;
//    while (y < tvYY) : (y += 1) {
//        if (nn) |nodeId| {
//            const node = tree.at(nodeId);
//            switch (node.key) {
//                .str => |s| {
//                    var str2 = s;
//                    while (try rx.captures(str2)) |cap| {
//                        defer cap.deinit();
//                        try keyfound.put(nodeId, .{ .start = @intCast(u32, cap.slots[0].?), .end = @intCast(u32, cap.slots[1].?) });
//                        str2 = str2[cap.slots[1].?..];
//                        break; // TODO: find all entries
//                    }
//                },
//                else => {},
//            }
//            if (node.collapsed) {
//                //drawPreview(node, tvXX);
//            } else {
//                if (node.value.len > 0) {
//                    //_ = c.printw(" %.*s ", c.COLS - node.level * 2 - 2 - 4 - 4, &node.content);
//                    var str2 = node.value;
//                    while (try rx.captures(str2)) |cap| {
//                        defer cap.deinit();
//                        try valfound.put(nodeId, .{ .start = @intCast(u32, cap.slots[0].?), .end = @intCast(u32, cap.slots[1].?) });
//                        str2 = str2[cap.slots[1].?..];
//                        break; // TODO: find all entries
//                    }
//                }
//            }
//            nn = node.nextVisibleId();
//        }
//    }
//}
