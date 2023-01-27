// This file contains Tree and Node data structure and associated tools,
// like position cache and data loader.
// For UI representation and parsing logic look into main.zig.

const std = @import("std");
const math = std.math;
pub const json = @import("zig-json5"); //https://github.com/Himujjal/zig-json5
const BoundedStack = @import("./containers.zig").BoundedStack;

pub const ID_T = u32;
pub const ROOT_ID: ID_T = 0;
pub const NO_ID: ID_T = math.maxInt(u32);
var tree = std.SegmentedList(Node, 1 << 10){}; // NOTE: not too large, this eats into EXE size (.data section)
// TODO: add LRU cache

pub const StrOrInt = union(enum) { str: []const u8, int: i32 };

pub fn len() u32 {
    return @intCast(u32, tree.len);
}

pub fn at(i: u32) *Node {
    return tree.at(i);
}

pub fn atY(y: u32) ?*Node {
    return tree.at(idAtY(y) orelse return null);
}

pub fn height() u32 {
    return at(ROOT_ID).height() - 1;
}

pub fn idAtY(y: u32) ?ID_T {
    if (y >= tree.len)
        return null;
    var currentPos: u32 = 0;
    var result = ROOT_ID;
    skipCache.lookup(y + 1, &currentPos, &result);
    var iteration: u32 = 0;
    while (currentPos <= y) : (iteration += 1) {
        if (iteration > 100e3) {
            iteration = 0;
            skipCache.put(currentPos, result);
        }
        const res = at(result);
        if (res.next != NO_ID and !res.collapsed and res.chHeight > 0 and res.chHeight < y - currentPos) {
            currentPos += res.chHeight + 1;
            result = res.next;
        } else {
            currentPos += 1;
            result = res.nextVisibleId() orelse return null;
        }
    }
    skipCache.put(y + 1, result);
    return result;
}

pub const Node = struct {
    collapsed: bool = false,
    level: u8,
    nType: enum { literal, obj, array } = .literal,
    parent: ID_T,
    next: ID_T = NO_ID,
    firstChild: ID_T = NO_ID,
    chHeight: u32 = 0,
    key: StrOrInt,
    value: []const u8 = "",

    pub fn nextVisible(self: Node) ?*Node {
        return tree.at(self.nextVisibleId() orelse return null);
    }

    pub fn nextVisibleId(self: Node) ?ID_T {
        var n = &self;
        if (n.firstChild != NO_ID and !n.collapsed)
            return n.firstChild;
        while (true) : (n = tree.at(n.parent))
            if (n.next != NO_ID) return n.next else if (n.parent == NO_ID) return null;
    }

    pub fn y(self: *const Node) u32 {
        if (self.parent == NO_ID)
            @panic("self.parent == NO_ID");
        var i: u32 = 0;
        _ = self.prevId(&i);
        if (self.parent == ROOT_ID)
            return i;
        return 1 + i + tree.at(self.parent).y();
    }

    pub fn prevId(self: *const Node, totalHeight: ?*u32) ID_T {
        if (self.parent == NO_ID)
            return NO_ID;
        var ch = tree.at(self.parent).firstChild;
        var result = NO_ID;
        while (ch != NO_ID) {
            const child = tree.at(ch);
            if (child == self)
                return result;
            result = ch;
            if (totalHeight) |th| th.* += child.height();
            ch = child.next;
        }
        unreachable;
    }

    pub fn height(self: Node) u32 {
        return 1 + if (self.collapsed) 0 else self.chHeight;
    }

    pub fn collapse(node: *Node, collapsed: bool) bool {
        if (node.firstChild == NO_ID or node.collapsed == collapsed)
            return false;
        node.collapsed = collapsed;
        const delta = node.chHeight;
        var n = node.parent;
        while (n != NO_ID) : (n = tree.at(n).parent) {
            if (collapsed) tree.at(n).chHeight -= delta else tree.at(n).chHeight += delta;
        }
        skipCache.drop();
        return true;
    }
};

var skipCache: struct {
    const Self = @This();
    const cacheSize = 8; // we do not need too many, only first and last two elements are mostly used
    ys: [cacheSize + 1]u32 = .{math.maxInt(u32)} ** (cacheSize + 1),
    ids: [cacheSize + 1]ID_T = .{NO_ID} ** (cacheSize + 1),

    fn cut(arr: anytype, i: u32) void {
        std.mem.copy(u32, arr[i..], arr[i + 1 ..]);
    }

    pub fn put(self: *Self, y: u32, id: ID_T) void {
        const h: i64 = height(); // u64 to allow some math
        var i: u32 = 0;
        while (i < cacheSize and self.ys[i] < y) : (i += 1) {}
        if (i < cacheSize) {
            if (self.ys[i] == y)
                return;
            if (self.ids[i] != NO_ID and i != 0) {
                const deltaLeft = math.absInt(y - @divTrunc(h * i, cacheSize)) catch unreachable;
                const deltaRight = math.absInt(y - @divTrunc(h * (i + 1), cacheSize)) catch unreachable;
                if (deltaLeft < deltaRight)
                    i -= 1;
            }
            self.ys[i] = y;
            self.ids[i] = id;
        } else {
            self.ys[cacheSize] = y;
            self.ids[cacheSize] = id;
            // decimate the cache
            i = 0;
            var smallestPenalty: i64 = math.maxInt(i64);
            var deleteIndex = i;
            while (i <= cacheSize) : (i += 1) {
                var penalty: i64 = 0;
                var j: u32 = 0;
                while (j < i) : (j += 1)
                    penalty += math.absInt(self.ys[j] - @divTrunc(h * (j + 1), cacheSize)) catch unreachable;
                j += 1;
                while (j <= cacheSize) : (j += 1)
                    penalty += math.absInt(self.ys[j] - @divTrunc(h * j, cacheSize)) catch unreachable;
                if (penalty <= smallestPenalty) {
                    smallestPenalty = penalty;
                    deleteIndex = i;
                }
            }
            if (deleteIndex < cacheSize) {
                cut(&self.ys, deleteIndex);
                cut(&self.ids, deleteIndex);
            }
        }
    }

    pub fn drop(self: *Self) void {
        self.ys = [_]u32{math.maxInt(u32)} ** (cacheSize + 1);
        self.ids = [_]ID_T{NO_ID} ** (cacheSize + 1);
    }

    pub fn lookup(self: Self, y: u32, currentPos: *u32, result: *ID_T) void {
        var i: u32 = 0;
        while (i < cacheSize and self.ys[i] <= y) : (i += 1) {}
        if (i > 0) {
            currentPos.* = self.ys[i - 1];
            result.* = self.ids[i - 1];
        }
    }
} = .{};

pub var loader: struct {
    const Self = @This();
    key: ?[]const u8 = null,
    allocator: std.mem.Allocator = std.heap.page_allocator,
    stateStack: BoundedStack(ParseState, 256) = .{},

    const ParseState = struct {
        parent: ID_T = NO_ID,
        prev: ID_T = NO_ID,
        mode: enum(u32) { normal, objKey, objValue } = .normal,
        nChildren: i32 = 0,
    };

    pub fn init(self: *Self) !void {
        try self.stateStack.push(.{});
        try self.load("", 0, .ArrayBegin);
    }

    fn propagateChHeight(self: *Self, chHeight: u32) void { // TODO: amortize this update
        for (self.stateStack.items()) |state| {
            if (state.parent != NO_ID)
                at(state.parent).chHeight += chHeight;
        }
    }

    pub fn load(self: *Self, slice: []u8, i: usize, token: json.Token) !void {
        var state = try self.stateStack.peek();
        switch (state.mode) {
            .normal, .objValue => {
                if (token == .ArrayEnd) {
                    _ = try self.stateStack.pop();
                    return;
                }
                const tn = @intCast(ID_T, tree.len);
                const node = try tree.addOne(self.allocator); // this pointer should be stable
                const key = if (state.mode == .objValue) StrOrInt{ .str = self.key.? } else StrOrInt{ .int = state.nChildren };
                node.* = .{ .level = @intCast(u8, self.stateStack.len - 1), .parent = state.parent, .key = key };
                if (state.prev != NO_ID) {
                    tree.at(state.prev).next = tn;
                } else if (state.parent != NO_ID) {
                    tree.at(state.parent).firstChild = tn;
                }
                state.nChildren += 1;
                self.propagateChHeight(1);
                switch (token) {
                    .ArrayBegin => {
                        node.nType = .array;
                        try self.stateStack.push(.{ .parent = tn });
                    },
                    .ObjectBegin => {
                        node.nType = .obj;
                        try self.stateStack.push(.{ .parent = tn, .mode = .objKey });
                    },
                    .Number => |s| node.value = slice[i - 1 - s.count .. i - 1],
                    .String => |s| node.value = slice[i - 2 - s.count .. i], // includes quotes
                    .True => node.value = "true",
                    .False => node.value = "false",
                    .Null => node.value = "null",
                    else => return error.ParseError,
                }
                state.prev = tn;
                if (state.mode == .objValue)
                    state.mode = .objKey;
            },
            .objKey => {
                switch (token) {
                    .ObjectEnd => {
                        _ = try self.stateStack.pop();
                    },
                    .String => |s| {
                        self.key = slice[i - 1 - s.count .. i - 1];
                        state.mode = .objValue;
                    },
                    else => return error.ParseError,
                }
            },
        }
    }
} = .{};
