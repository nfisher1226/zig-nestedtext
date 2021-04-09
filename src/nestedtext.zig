const std = @import("std");
const json = std.json;
const testing = std.testing;
const assert = std.debug.assert;

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const StringArrayHashMap = std.StringArrayHashMap;
const Writer = std.io.Writer;

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

/// Return a slice corresponding to the first line of the given input,
/// including the terminating newline character(s). If there is no terminating
/// newline the entire input slice is returned. Returns null if the input is
/// empty.
fn readline(input: []const u8) ?[]const u8 {
    if (input.len == 0) return null;
    var idx: usize = 0;
    while (idx < input.len) {
        // Handle '\n'
        if (input[idx] == '\n') {
            idx += 1;
            break;
        }
        // Handle '\r'
        if (input[idx] == '\r') {
            idx += 1;
            // Handle '\r\n'
            if (input.len >= idx and input[idx] == '\n') idx += 1;
            break;
        }
        idx += 1;
    }
    return input[0..idx];
}

// -----------------------------------------------------------------------------
// Types
// -----------------------------------------------------------------------------

const StringifyOptions = struct {
    indent: usize = 2,
};

pub const ValueTree = struct {
    arena: ArenaAllocator,
    root: Value,

    pub fn deinit(self: @This()) void {
        self.arena.deinit();
    }
};

pub const Map = StringArrayHashMap(Value);
pub const Array = ArrayList(Value);

pub const Value = union(enum) {
    String: []const u8,
    List: Array,
    Object: Map,

    pub fn stringify(
        value: @This(),
        options: StringifyOptions,
        out_stream: anytype,
    ) @TypeOf(out_stream).Error!void {
        try value.stringifyInternal(options, out_stream, 0, false);
    }

    pub fn toJson(value: @This(), allocator: *Allocator) !json.ValueTree {
        var json_tree: json.ValueTree = undefined;
        json_tree.arena = ArenaAllocator.init(allocator);
        json_tree.root = try value.toJsonValue(&json_tree.arena.allocator);
        return json_tree;
    }

    fn toJsonValue(value: @This(), allocator: *Allocator) anyerror!json.Value {
        switch (value) {
            .String => |inner| return json.Value{ .String = inner },
            .List => |inner| {
                var json_array = json.Array.init(allocator);
                for (inner.items) |elem| {
                    const json_elem = try elem.toJsonValue(allocator);
                    try json_array.append(json_elem);
                }
                return json.Value{ .Array = json_array };
            },
            .Object => |inner| {
                var json_map = json.ObjectMap.init(allocator);
                var iter = inner.iterator();
                while (iter.next()) |elem| {
                    const json_value = try elem.value.toJsonValue(allocator);
                    try json_map.put(elem.key, json_value);
                }
                return json.Value{ .Object = json_map };
            },
        }
    }

    fn stringifyInternal(
        value: @This(),
        options: StringifyOptions,
        out_stream: anytype,
        indent: usize,
        nested: bool,
    ) @TypeOf(out_stream).Error!void {
        switch (value) {
            .String => |string| {
                if (std.mem.indexOfAny(u8, string, "\r\n") == null) {
                    // Single-line string.
                    if (nested and string.len > 0) try out_stream.writeByte(' ');
                    try out_stream.writeAll(string);
                } else {
                    // Multi-line string.
                    if (nested) try out_stream.writeByte('\n');
                    var idx: usize = 0;
                    while (readline(string[idx..])) |line| {
                        try out_stream.writeByteNTimes(' ', indent);
                        try out_stream.writeByte('>');
                        if (line.len > 0)
                            try out_stream.print(" {s}", .{line});
                        idx += line.len;
                    }
                    const last_char = string[string.len - 1];
                    if (last_char == '\n' or last_char == '\r') {
                        try out_stream.writeByteNTimes(' ', indent);
                        try out_stream.writeByte('>');
                    }
                }
            },
            .List => |list| {
                if (nested) try out_stream.writeByte('\n');
                for (list.items) |*elem| {
                    if (elem != &list.items[0]) try out_stream.writeByte('\n');
                    try out_stream.writeByteNTimes(' ', indent);
                    try out_stream.writeByte('-');
                    try elem.stringifyInternal(
                        options,
                        out_stream,
                        indent + options.indent,
                        true,
                    );
                }
            },
            .Object => |object| {
                if (nested) try out_stream.writeByte('\n');
                var iter = object.iterator();
                var first_elem = true;
                while (iter.next()) |elem| {
                    if (!first_elem) try out_stream.writeByte('\n');
                    try out_stream.writeByteNTimes(' ', indent);
                    try out_stream.print("{s}:", .{elem.key});
                    try elem.value.stringifyInternal(
                        options,
                        out_stream,
                        indent + options.indent,
                        true,
                    );
                    first_elem = false;
                }
            },
        }
    }
};

/// Memory owned by caller on success - free with 'ValueTree.deinit()'.
pub fn fromJson(allocator: *Allocator, json_value: json.Value) !ValueTree {
    var tree: ValueTree = undefined;
    tree.arena = ArenaAllocator.init(allocator);
    errdefer tree.deinit();
    tree.root = try fromJsonInternal(&tree.arena.allocator, json_value);
    return tree;
}

fn fromJsonInternal(allocator: *Allocator, json_value: json.Value) anyerror!Value {
    switch (json_value) {
        .Null => return Value{ .String = "null" },
        .Bool => |inner| return Value{ .String = if (inner) "true" else "false" },
        .Integer, .Float, .String => {
            var buffer = ArrayList(u8).init(allocator);
            errdefer buffer.deinit();
            switch (json_value) {
                .Integer => |inner| {
                    try buffer.writer().print("{d}", .{inner});
                },
                .Float => |inner| {
                    try buffer.writer().print("{e}", .{inner});
                },
                .String => |inner| {
                    try buffer.writer().print("{s}", .{inner});
                },
                else => unreachable,
            }
            return Value{ .String = buffer.items };
        },
        .Array => |inner| {
            var array = Array.init(allocator);
            for (inner.items) |elem| {
                try array.append(try fromJsonInternal(allocator, elem));
            }
            return Value{ .List = array };
        },
        .Object => |inner| {
            var map = Map.init(allocator);
            var iter = inner.iterator();
            while (iter.next()) |elem| {
                try map.put(
                    try allocator.dupe(u8, elem.key),
                    try fromJsonInternal(allocator, elem.value),
                );
            }
            return Value{ .Object = map };
        },
    }
}

// -----------------------------------------------------------------------------
// Parsing logic
// -----------------------------------------------------------------------------

pub const Parser = struct {
    allocator: *Allocator,
    options: ParseOptions,

    const Self = @This();

    pub const ParseOptions = struct {
        /// Behaviour when a duplicate field is encountered.
        duplicate_field_behavior: enum {
            UseFirst,
            UseLast,
            Error,
        } = .Error,

        /// Whether to copy strings or return existing slices.
        copy_strings: bool = true,
    };

    const LineType = union(enum) {
        Blank,
        Comment,
        String: struct { depth: usize, value: []const u8 },
        List: struct { depth: usize, value: ?[]const u8 },
        Object: struct { depth: usize, key: []const u8, value: ?[]const u8 },
        Unrecognised,
    };

    const Line = struct {
        text: []const u8,
        lineno: usize,
        kind: LineType,
    };

    const LinesIter = struct {
        next_idx: usize,
        lines: ArrayList(Line),

        pub fn init(lines: ArrayList(Line)) LinesIter {
            var self = LinesIter{ .next_idx = 0, .lines = lines };
            self.skipIgnorableLines();
            return self;
        }

        pub fn next(self: *LinesIter) ?Line {
            if (self.next_idx >= self.len()) return null;
            const line = self.lines.items[self.next_idx];
            self.advanceToNextContentLine();
            return line;
        }

        pub fn peekNext(self: LinesIter) ?Line {
            if (self.next_idx >= self.len()) return null;
            return self.lines.items[self.next_idx];
        }

        pub fn peekNextDepth(self: LinesIter) ?usize {
            if (self.peekNext() == null) return null;
            return switch (self.peekNext().?.kind) {
                .String => |k| k.depth,
                .List => |k| k.depth,
                .Object => |k| k.depth,
                else => null,
            };
        }

        fn len(self: LinesIter) usize {
            return self.lines.items.len;
        }

        fn advanceToNextContentLine(self: *LinesIter) void {
            self.next_idx += 1;
            self.skipIgnorableLines();
        }

        fn skipIgnorableLines(self: *LinesIter) void {
            while (self.next_idx < self.len()) {
                switch (self.lines.items[self.next_idx].kind) {
                    .Blank, .Comment => self.next_idx += 1,
                    else => return,
                }
            }
        }
    };

    pub fn init(allocator: *Allocator, options: ParseOptions) Self {
        return .{
            .allocator = allocator,
            .options = options,
        };
    }

    /// Memory owned by caller on success - free with 'ValueTree.deinit()'.
    pub fn parse(p: Self, input: []const u8) !ValueTree {
        var tree: ValueTree = undefined;
        tree.arena = ArenaAllocator.init(p.allocator);
        errdefer tree.deinit();

        // TODO: This should be an iterator, i.e. don't loop over all lines
        //       up front (unnecessary performance and memory cost). We should
        //       only need access to the current (and next?) line.
        //       Note that it's only the struct instances that are allocated,
        //       the string slices are from the input and owned by the caller.
        const lines = try p.parseLines(input);
        defer lines.deinit();

        var iter = LinesIter.init(lines);

        tree.root = if (iter.peekNext() != null)
            try p.readValue(&tree.arena.allocator, &iter) // Recursively parse
        else
            .{ .String = "" };

        return tree;
    }

    /// Split the given input into an array of lines, where each entry is a
    /// struct instance containing relevant info.
    fn parseLines(p: Self, input: []const u8) !ArrayList(Line) {
        var lines_array = ArrayList(Line).init(p.allocator);
        var buf_idx: usize = 0;
        var lineno: usize = 0;
        while (readline(input[buf_idx..])) |full_line| {
            buf_idx += full_line.len;
            const text = std.mem.trimRight(u8, full_line, &[_]u8{ '\n', '\r' });
            lineno += 1;
            var kind: LineType = undefined;

            // TODO: Check leading space is entirely made up of space characters.
            const stripped = std.mem.trimLeft(u8, text, &[_]u8{ ' ', '\t' });
            const depth = text.len - stripped.len;
            if (stripped.len == 0) {
                kind = .Blank;
            } else if (stripped[0] == '#') {
                kind = .Comment;
            } else if (parseString(stripped)) |index| {
                kind = .{
                    .String = .{
                        .depth = depth,
                        .value = full_line[text.len - stripped.len + index ..],
                    },
                };
            } else if (parseList(stripped)) |value| {
                kind = .{
                    .List = .{
                        .depth = depth,
                        .value = if (value.len > 0) value else null,
                    },
                };
            } else if (parseObject(stripped)) |result| {
                kind = .{
                    .Object = .{
                        .depth = depth,
                        .key = result[0].?,
                        // May be null if the value is on the following line(s).
                        .value = result[1],
                    },
                };
            } else {
                kind = .Unrecognised;
            }
            try lines_array.append(
                Line{
                    .text = text,
                    .lineno = lineno,
                    .kind = kind,
                },
            );
        }
        return lines_array;
    }

    fn parseString(text: []const u8) ?usize {
        assert(text.len > 0);
        if (text[0] != '>') return null;
        if (text.len == 1) return 1;
        if (text[1] == ' ') return 2;
        return null;
    }

    fn parseList(text: []const u8) ?[]const u8 {
        assert(text.len > 0);
        if (text[0] != '-') return null;
        if (text.len == 1) return "";
        if (text[1] == ' ') return text[2..];
        return null;
    }

    fn parseObject(text: []const u8) ?[2]?[]const u8 {
        // TODO: Handle edge cases!
        for (text) |char, i| {
            if (char == ' ') return null;
            if (char == ':') {
                // Assume first colon found is the key-value separator, and
                // expect a space character to follow if anything.
                if (text.len > i + 1 and text[i + 1] != ' ') return null;
                const value = if (text.len > i + 2) text[i + 2 ..] else null;
                return [_]?[]const u8{ text[0..i], value };
            }
        }
        return null;
    }

    fn readValue(p: Self, allocator: *Allocator, lines: *LinesIter) anyerror!Value {
        // Call read<type>() with the first line of the type queued up as the
        // next line in the lines iterator.
        return switch (lines.peekNext().?.kind) {
            .String => .{ .String = try p.readString(allocator, lines) },
            .List => .{ .List = try p.readList(allocator, lines) },
            .Object => .{ .Object = try p.readObject(allocator, lines) },
            .Unrecognised => error.UnrecognisedLine,
            .Blank, .Comment => unreachable, // Skipped by iterator
        };
    }

    fn readString(p: Self, allocator: *Allocator, lines: *LinesIter) ![]const u8 {
        var buffer = ArrayList(u8).init(allocator);
        errdefer buffer.deinit();
        var writer = buffer.writer();

        assert(lines.peekNext().?.kind == .String);
        const depth = lines.peekNext().?.kind.String.depth;

        while (lines.next()) |line| {
            if (line.kind != .String) return error.InvalidItem;
            const is_last_line = lines.peekNextDepth() == null or lines.peekNextDepth().? < depth;
            const str_line = line.kind.String;
            if (str_line.depth > depth) return error.InvalidIndentation;
            // String must be copied as it's not contiguous in-file.
            if (is_last_line)
                try writer.writeAll(std.mem.trimRight(u8, str_line.value, &[_]u8{ '\n', '\r' }))
            else
                try writer.writeAll(str_line.value);
            if (is_last_line) break;
        }
        return buffer.items;
    }

    fn readList(p: Self, allocator: *Allocator, lines: *LinesIter) !Array {
        var array = Array.init(allocator);
        errdefer array.deinit();

        assert(lines.peekNext().?.kind == .List);
        const depth = lines.peekNext().?.kind.List.depth;

        while (lines.next()) |line| {
            if (line.kind != .List) return error.InvalidItem;
            const list_line = line.kind.List;
            if (list_line.depth > depth) return error.InvalidIndentation;

            var value: Value = undefined;
            if (list_line.value) |str| {
                value = .{ .String = try p.maybeDupString(allocator, str) };
            } else if (lines.peekNextDepth() != null and lines.peekNextDepth().? > depth) {
                value = try p.readValue(allocator, lines);
            } else {
                value = .{ .String = "" };
            }
            try array.append(value);

            if (lines.peekNextDepth() != null and lines.peekNextDepth().? < depth) break;
        }
        return array;
    }

    fn readObject(p: Self, allocator: *Allocator, lines: *LinesIter) anyerror!Map {
        var map = Map.init(allocator);
        errdefer map.deinit();

        assert(lines.peekNext().?.kind == .Object);
        const depth = lines.peekNext().?.kind.Object.depth;

        while (lines.next()) |line| {
            if (line.kind != .Object) return error.InvalidItem;
            const obj_line = line.kind.Object;
            if (obj_line.depth > depth) return error.InvalidIndentation;

            var value: Value = undefined;
            if (obj_line.value) |str| {
                value = .{ .String = try p.maybeDupString(allocator, str) };
            } else if (lines.peekNextDepth() != null and lines.peekNextDepth().? > depth) {
                value = try p.readValue(allocator, lines);
            } else {
                value = .{ .String = "" };
            }
            try map.put(try p.maybeDupString(allocator, obj_line.key), value);

            if (lines.peekNextDepth() != null and lines.peekNextDepth().? < depth) break;
        }
        return map;
    }

    fn maybeDupString(p: Self, allocator: *Allocator, string: []const u8) ![]const u8 {
        return if (p.options.copy_strings) try allocator.dupe(u8, string) else string;
    }
};

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "parse empty" {
    var p = Parser.init(testing.allocator, .{});

    var tree = try p.parse("");
    defer tree.deinit();

    testing.expectEqual(Value{.String=""}, tree.root);
}

test "basic parse: string" {
    var p = Parser.init(testing.allocator, .{});

    const s =
        \\ > this is a
        \\ > multiline
        \\ > string
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    testing.expectEqualStrings("this is a\nmultiline\nstring", tree.root.String);
}

test "basic parse: list" {
    var p = Parser.init(testing.allocator, .{});

    const s =
        \\ - foo
        \\ - bar
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    const array: Array = tree.root.List;

    testing.expectEqualStrings("foo", array.items[0].String);
    testing.expectEqualStrings("bar", array.items[1].String);
}

test "basic parse: object" {
    var p = Parser.init(testing.allocator, .{});

    const s =
        \\ foo: 1
        \\ bar: False
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    const map: Map = tree.root.Object;

    testing.expectEqualStrings("1", map.get("foo").?.String);
    testing.expectEqualStrings("False", map.get("bar").?.String);
}

test "nested parse: object inside object" {
    var p = Parser.init(testing.allocator, .{});

    const s =
        \\ foo: 1
        \\ bar:
        \\   nest1: 2
        \\   nest2: 3
        \\ baz:
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    const map: Map = tree.root.Object;

    testing.expectEqualStrings("1", map.get("foo").?.String);
    testing.expectEqualStrings("", map.get("baz").?.String);
    testing.expectEqualStrings("2", map.get("bar").?.Object.get("nest1").?.String);
    testing.expectEqualStrings("3", map.get("bar").?.Object.get("nest2").?.String);
}

test "stringify: empty" {
    var p = Parser.init(testing.allocator, .{});

    var tree = try p.parse("");
    defer tree.deinit();

    var buffer: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try tree.root.stringify(.{}, fbs.outStream());
    testing.expectEqualStrings("", fbs.getWritten());
}

test "stringify: string" {
    var p = Parser.init(testing.allocator, .{});

    const s =
        \\> this is a
        \\> multiline
        \\> string
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    var buffer: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try tree.root.stringify(.{}, fbs.outStream());
    testing.expectEqualStrings(s, fbs.getWritten());
}

test "stringify: list" {
    var p = Parser.init(testing.allocator, .{});

    const s =
        \\- foo
        \\- bar
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    var buffer: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try tree.root.stringify(.{}, fbs.outStream());
    testing.expectEqualStrings(s, fbs.getWritten());
}

test "stringify: object" {
    var p = Parser.init(testing.allocator, .{});

    const s =
        \\foo: 1
        \\bar: False
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    var buffer: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try tree.root.stringify(.{}, fbs.outStream());
    testing.expectEqualStrings(s, fbs.getWritten());
}

test "stringify: multiline string inside object" {
    var p = Parser.init(testing.allocator, .{});

    const s =
        \\foo:
        \\  > multi
        \\  > line
        \\bar:
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    var buffer: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try tree.root.stringify(.{}, fbs.outStream());
    testing.expectEqualStrings(s, fbs.getWritten());
}

test "convert to JSON: empty" {
    var p = Parser.init(testing.allocator, .{});

    var tree = try p.parse("");
    defer tree.deinit();

    var json_tree = try tree.root.toJson(testing.allocator);
    defer json_tree.deinit();

    var buffer: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try json_tree.root.jsonStringify(.{}, fbs.outStream());
    testing.expectEqualStrings("\"\"", fbs.getWritten());
}

test "convert to JSON: string" {
    var p = Parser.init(testing.allocator, .{});

    const s =
        \\ > this is a
        \\ > multiline
        \\ > string
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    var json_tree = try tree.root.toJson(testing.allocator);
    defer json_tree.deinit();

    var buffer: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try json_tree.root.jsonStringify(.{}, fbs.outStream());
    testing.expectEqualStrings("\"this is a\\nmultiline\\nstring\"", fbs.getWritten());
}

test "convert to JSON: list" {
    var p = Parser.init(testing.allocator, .{});

    const s =
        \\ - foo
        \\ - bar
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    var json_tree = try tree.root.toJson(testing.allocator);
    defer json_tree.deinit();

    var buffer: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try json_tree.root.jsonStringify(.{}, fbs.outStream());
    const expected_json =
        \\["foo","bar"]
    ;
    testing.expectEqualStrings(expected_json, fbs.getWritten());
}

test "convert to JSON: object" {
    var p = Parser.init(testing.allocator, .{});

    const s =
        \\ foo: 1
        \\ bar: False
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    var json_tree = try tree.root.toJson(testing.allocator);
    defer json_tree.deinit();

    var buffer: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try json_tree.root.jsonStringify(.{}, fbs.outStream());
    // TODO: Order of objects not yet guaranteed.
    const expected_json =
        \\{"foo":"1","bar":"False"}
    ;
    testing.expectEqualStrings(expected_json, fbs.getWritten());
}

test "convert to JSON: object inside object" {
    var p = Parser.init(testing.allocator, .{});

    const s =
        \\ bar:
        \\   nest1: 1
        \\   nest2: 2
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    var json_tree = try tree.root.toJson(testing.allocator);
    defer json_tree.deinit();

    var buffer: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try json_tree.root.jsonStringify(.{}, fbs.outStream());
    const expected_json =
        \\{"bar":{"nest1":"1","nest2":"2"}}
    ;
    testing.expectEqualStrings(expected_json, fbs.getWritten());
}

test "convert to JSON: list inside object" {
    var p = Parser.init(testing.allocator, .{});

    const s =
        \\ bar:
        \\   - nest1
        \\   - nest2
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    var json_tree = try tree.root.toJson(testing.allocator);
    defer json_tree.deinit();

    var buffer: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try json_tree.root.jsonStringify(.{}, fbs.outStream());
    const expected_json =
        \\{"bar":["nest1","nest2"]}
    ;
    testing.expectEqualStrings(expected_json, fbs.getWritten());
}

test "convert to JSON: multiline string inside object" {
    var p = Parser.init(testing.allocator, .{});

    const s =
        \\ foo:
        \\   > multi
        \\   > line
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    var json_tree = try tree.root.toJson(testing.allocator);
    defer json_tree.deinit();

    var buffer: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try json_tree.root.jsonStringify(.{}, fbs.outStream());
    const expected_json =
        \\{"foo":"multi\nline"}
    ;
    testing.expectEqualStrings(expected_json, fbs.getWritten());
}

test "convert to JSON: multiline string inside list" {
    var p = Parser.init(testing.allocator, .{});

    const s =
        \\ -
        \\   > multi
        \\   > line
        \\ -
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    var json_tree = try tree.root.toJson(testing.allocator);
    defer json_tree.deinit();

    var buffer: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try json_tree.root.jsonStringify(.{}, fbs.outStream());
    const expected_json =
        \\["multi\nline",""]
    ;
    testing.expectEqualStrings(expected_json, fbs.getWritten());
}
