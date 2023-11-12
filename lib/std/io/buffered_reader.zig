const std = @import("../std.zig");
const io = std.io;
const mem = std.mem;
const assert = std.debug.assert;
const testing = std.testing;

pub fn BufferedReader(comptime buffer_size: usize, comptime ReaderType: type) type {
    return struct {
        unbuffered_reader: ReaderType,
        buf: [buffer_size]u8 = undefined,
        start: usize = 0,
        end: usize = 0,

        pub const Error = ReaderType.Error;
        pub const Reader = io.Reader(*Self, Error, read);

        const Self = @This();

        pub fn read(self: *Self, dest: []u8) Error!usize {
            var dest_index: usize = 0;

            while (dest_index < dest.len) {
                const written = @min(dest.len - dest_index, self.end - self.start);
                @memcpy(dest[dest_index..][0..written], self.buf[self.start..][0..written]);
                if (written == 0) {
                    if (try self.fill() == false) {
                        // reading from the unbuffered stream returned nothing
                        // so we have nothing left to read.
                        return dest_index;
                    }
                }
                self.start += written;
                dest_index += written;
            }
            return dest.len;
        }

        pub fn streamUntilDelimiter(
            self: *Self,
            writer: anytype,
            delimiter: u8,
            optional_max_size: ?usize,
        ) (Reader.Error || error{ StreamTooLong, EndOfStream } || @TypeOf(writer).Error)!void {
            // Implemented directly, rather than relying on a more generic
            // solution from io.Reader to leverage our buffer for performance.
            var written: usize = 0;
            while (true) {
                const start = self.start;
                const pos = std.mem.indexOfScalar(u8, self.buf[start..self.end], delimiter) orelse self.end - start;

                const delimiter_pos = start + pos;
                if (optional_max_size) |max| {
                    written += delimiter_pos - start;
                    if (written > max) {
                        return error.StreamTooLong;
                    }
                }

                try writer.writeAll(self.buf[start..delimiter_pos]);

                // Our call to indexOfScalar handles not found by orlse'ing with
                // self.end - start. This creates a single codepath, above, where
                // we check optional_max_size and write into writer. However,
                // if indexOfScalar did find the delimiter, then we're done. If
                // it didn't, then we need to fill our buffer and keep looking.
                if (delimiter_pos != self.end) {
                    // +1 to skip over the delimiter
                    self.start = delimiter_pos + 1;
                    return;
                }

                if (try self.fill() == false) {
                    return error.EndOfStream;
                }
            }
        }

        pub fn reader(self: *Self) Reader {
            return .{ .context = self };
        }

        fn fill(self: *Self) !bool {
            // buf empty, fill it
            const n = try self.unbuffered_reader.read(self.buf[0..]);
            if (n == 0) {
                return false;
            }
            self.start = 0;
            self.end = n;
            return true;
        }
    };
}

pub fn bufferedReader(reader: anytype) BufferedReader(4096, @TypeOf(reader)) {
    return .{ .unbuffered_reader = reader };
}

pub fn bufferedReaderSize(comptime size: usize, reader: anytype) BufferedReader(size, @TypeOf(reader)) {
    return .{ .unbuffered_reader = reader };
}

test "io.BufferedReader OneByte" {
    const OneByteReadReader = struct {
        str: []const u8,
        curr: usize,

        const Error = error{NoError};
        const Self = @This();
        const Reader = io.Reader(*Self, Error, read);

        fn init(str: []const u8) Self {
            return Self{
                .str = str,
                .curr = 0,
            };
        }

        fn read(self: *Self, dest: []u8) Error!usize {
            if (self.str.len <= self.curr or dest.len == 0)
                return 0;

            dest[0] = self.str[self.curr];
            self.curr += 1;
            return 1;
        }

        fn reader(self: *Self) Reader {
            return .{ .context = self };
        }
    };

    const str = "This is a test";
    var one_byte_stream = OneByteReadReader.init(str);
    var buf_reader = bufferedReader(one_byte_stream.reader());
    const stream = buf_reader.reader();

    const res = try stream.readAllAlloc(testing.allocator, str.len + 1);
    defer testing.allocator.free(res);
    try testing.expectEqualSlices(u8, str, res);
}

fn smallBufferedReader(underlying_stream: anytype) BufferedReader(8, @TypeOf(underlying_stream)) {
    return .{ .unbuffered_reader = underlying_stream };
}
test "io.BufferedReader Block" {
    const BlockReader = struct {
        block: []const u8,
        reads_allowed: usize,
        curr_read: usize,

        const Error = error{NoError};
        const Self = @This();
        const Reader = io.Reader(*Self, Error, read);

        fn init(block: []const u8, reads_allowed: usize) Self {
            return Self{
                .block = block,
                .reads_allowed = reads_allowed,
                .curr_read = 0,
            };
        }

        fn read(self: *Self, dest: []u8) Error!usize {
            if (self.curr_read >= self.reads_allowed) return 0;
            @memcpy(dest[0..self.block.len], self.block);

            self.curr_read += 1;
            return self.block.len;
        }

        fn reader(self: *Self) Reader {
            return .{ .context = self };
        }
    };

    const block = "0123";

    // len out == block
    {
        var block_reader = BlockReader.init(block, 2);
        var test_buf_reader = BufferedReader(4, BlockReader){ .unbuffered_reader = block_reader };
        var out_buf: [4]u8 = undefined;
        _ = try test_buf_reader.read(&out_buf);
        try testing.expectEqualSlices(u8, &out_buf, block);
        _ = try test_buf_reader.read(&out_buf);
        try testing.expectEqualSlices(u8, &out_buf, block);
        try testing.expectEqual(try test_buf_reader.read(&out_buf), 0);
    }

    // len out < block
    {
        var block_reader = BlockReader.init(block, 2);
        var test_buf_reader = BufferedReader(4, BlockReader){ .unbuffered_reader = block_reader };
        var out_buf: [3]u8 = undefined;
        _ = try test_buf_reader.read(&out_buf);
        try testing.expectEqualSlices(u8, &out_buf, "012");
        _ = try test_buf_reader.read(&out_buf);
        try testing.expectEqualSlices(u8, &out_buf, "301");
        const n = try test_buf_reader.read(&out_buf);
        try testing.expectEqualSlices(u8, out_buf[0..n], "23");
        try testing.expectEqual(try test_buf_reader.read(&out_buf), 0);
    }

    // len out > block
    {
        var block_reader = BlockReader.init(block, 2);
        var test_buf_reader = BufferedReader(4, BlockReader){ .unbuffered_reader = block_reader };
        var out_buf: [5]u8 = undefined;
        _ = try test_buf_reader.read(&out_buf);
        try testing.expectEqualSlices(u8, &out_buf, "01230");
        const n = try test_buf_reader.read(&out_buf);
        try testing.expectEqualSlices(u8, out_buf[0..n], "123");
        try testing.expectEqual(try test_buf_reader.read(&out_buf), 0);
    }

    // len out == 0
    {
        var block_reader = BlockReader.init(block, 2);
        var test_buf_reader = BufferedReader(4, BlockReader){ .unbuffered_reader = block_reader };
        var out_buf: [0]u8 = undefined;
        _ = try test_buf_reader.read(&out_buf);
        try testing.expectEqualSlices(u8, &out_buf, "");
    }

    // len bufreader buf > block
    {
        var block_reader = BlockReader.init(block, 2);
        var test_buf_reader = BufferedReader(5, BlockReader){ .unbuffered_reader = block_reader };
        var out_buf: [4]u8 = undefined;
        _ = try test_buf_reader.read(&out_buf);
        try testing.expectEqualSlices(u8, &out_buf, block);
        _ = try test_buf_reader.read(&out_buf);
        try testing.expectEqualSlices(u8, &out_buf, block);
        try testing.expectEqual(try test_buf_reader.read(&out_buf), 0);
    }
}

test "io.bufferedReader streamUntilDelimiter no max" {
    inline for ([_]usize{ 3, 256 }) |buffer_size| {
        const input = "It's over 9000! WHAT?! Over 9000?!";
        var unbuffered = std.io.fixedBufferStream(input[0..]);

        var out: [32]u8 = undefined;
        var out_stream = std.io.fixedBufferStream(&out);
        var out_writer = out_stream.writer();

        var reader = bufferedReaderSize(buffer_size, unbuffered.reader());

        try reader.streamUntilDelimiter(out_writer, '!', null);
        try testing.expectEqualStrings("It's over 9000", out_stream.getWritten());

        out_stream.reset();
        try reader.streamUntilDelimiter(out_writer, '!', null);
        try testing.expectEqualStrings(" WHAT?", out_stream.getWritten());

        out_stream.reset();
        try reader.streamUntilDelimiter(out_writer, '!', null);
        try testing.expectEqualStrings(" Over 9000?", out_stream.getWritten());

        try testing.expectError(error.EndOfStream, reader.streamUntilDelimiter(out_writer, '!', null));
    }
}

test "io.bufferedReader streamUntilDelimiter max" {
    inline for ([_]usize{ 3, 256 }) |buffer_size| {
        const input = "It's over 9000! WHAT?! Over 9000?!";
        var unbuffered = std.io.fixedBufferStream(input[0..]);

        var out: [22]u8 = undefined;
        var out_stream = std.io.fixedBufferStream(&out);
        var out_writer = out_stream.writer();

        var reader = bufferedReaderSize(buffer_size, unbuffered.reader());

        try reader.streamUntilDelimiter(out_writer, '!', null);
        try testing.expectEqualStrings("It's over 9000", out_stream.getWritten());

        // no out_stream reset!
        try reader.streamUntilDelimiter(out_writer, '!', null);
        try testing.expectEqualStrings("It's over 9000 WHAT?", out_stream.getWritten());

        try testing.expectError(error.NoSpaceLeft, reader.streamUntilDelimiter(out_writer, '!', null));
    }
}
