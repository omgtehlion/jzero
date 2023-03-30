const std = @import("std");
const Allocator = std.mem.Allocator;

/// This is a data structure which stores data in dynamically allocated arrays of fixed size.
/// Pointers to elements are stable (have the same lifetime as the data structure), like in SegmentedList.
/// The structure is not designed to be accessed per-element, use slices instead.
pub fn ChunkedList(comptime T: type, comptime chunkSize: usize) type {
    return struct {
        const Self = @This();
        allocator: Allocator,
        chunks: std.ArrayList([]T),
        /// Total length of committed data (in elements).
        len: usize = 0,

        /// Deinitialize with `deinit`.
        pub fn init(allocator: Allocator) Self {
            return Self{
                .allocator = allocator,
                .chunks = std.ArrayList([]T).init(allocator),
            };
        }

        /// Release all allocated memory.
        pub fn deinit(self: *Self) void {
            for (self.chunks.items) |chunk|
                self.allocator.free(chunk.ptr[0..chunkSize]);
            self.chunks.deinit();
        }

        fn lastSlice(self: *Self) ?*[]T {
            if (self.chunks.items.len == 0)
                return null;
            return &self.chunks.items[self.chunks.items.len - 1];
        }

        fn addSlice(self: *Self) ![]T {
            const result = (try self.allocator.alloc(T, chunkSize))[0..0];
            try self.chunks.append(result);
            return result;
        }

        const SlicePair = struct {
            base: [*]T,
            offset: usize,
            pub fn fresh(self: *SlicePair) []T {
                return self.base[self.offset..chunkSize];
            }
            pub fn fromStart(self: *SlicePair, length: usize) []T {
                if (length > chunkSize)
                    std.debug.panic("length > chunkSize", .{});
                return self.base[0..length];
            }
        };

        /// Get a slice to store new data into, this might be a new slice or tail of previously used one.
        pub fn getSlice(self: *Self, minFree: usize) !SlicePair {
            if (minFree > chunkSize)
                return error.SizeError;
            if (self.lastSlice()) |slice| {
                const free = chunkSize - slice.len;
                if (free >= minFree)
                    return .{ .base = slice.ptr, .offset = slice.len };
            }
            return .{ .base = (try self.addSlice()).ptr, .offset = 0 };
        }

        /// Call this method when you finished storing new data into previously acquired slice.
        pub fn commit(self: *Self, count: usize) !void {
            if (self.lastSlice()) |slice| {
                const free = chunkSize - slice.len;
                if (free < count)
                    return error.SizeError;
                slice.len += count;
                self.len += count;
            } else {
                return error.Ooops;
            }
        }
    };
}

/// This data structure represents a Stack (LIFO collection).
/// Which is allocated statically and its capacity is determined at compile time.
pub fn BoundedStack(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();
        /// Backing store of the whole stack. To enumerate pushed elements, use items().
        data: [capacity]T = undefined,
        len: usize = 0,

        pub fn push(self: *Self, item: T) !void {
            if (self.len >= capacity)
                return error.StackFullError;
            self.data[self.len] = item;
            self.len += 1;
        }

        pub fn peek(self: *Self) !*T {
            if (self.len == 0)
                return error.StackEmptyError;
            return &self.data[self.len - 1];
        }

        pub fn pop(self: *Self) !*T {
            defer self.len -= 1;
            return try self.peek();
        }

        /// Enumerates all pushed elements in reverse (FIFO) order
        pub fn items(self: *Self) []T {
            return self.data[0..self.len];
        }
    };
}
