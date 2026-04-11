const std = @import("std");
const vaxis = @import("vaxis");

const sample_json =
    \\{
    \\  "plug": "lovely-sauteeing-charm",
    \\  "status": "running",
    \\  "progress": 42,
    \\  "active": true,
    \\  "error": null,
    \\  "tags": ["tui", "vaxis", "zig"],
    \\  "meta": { "owner": "arthack", "retries": 0 }
    \\}
;

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

const JsonRenderer = struct {
    win: vaxis.Window,
    row: u16,

    fn emit(self: *JsonRenderer, col: u16, text: []const u8) void {
        _ = self.win.printSegment(.{ .text = text }, .{ .col_offset = col, .row_offset = self.row });
    }

    fn nextRow(self: *JsonRenderer) void {
        self.row +|= 1;
    }

    fn renderValue(self: *JsonRenderer, value: std.json.Value, col: u16, indent: u16) void {
        switch (value) {
            .object => |obj| {
                if (obj.count() == 0) {
                    self.emit(col, "{}");
                    self.nextRow();
                    return;
                }
                self.emit(col, "{");
                self.nextRow();
                var it = obj.iterator();
                while (it.next()) |entry| {
                    const key = entry.key_ptr.*;
                    const klen: u16 = @intCast(@min(key.len, 500));
                    self.emit(indent + 2, key);
                    self.emit(indent + 2 + klen, ": ");
                    self.renderValue(entry.value_ptr.*, indent + 2 + klen + 2, indent + 2);
                }
                self.emit(indent, "}");
                self.nextRow();
            },
            .array => |arr| {
                if (arr.items.len == 0) {
                    self.emit(col, "[]");
                    self.nextRow();
                    return;
                }
                self.emit(col, "[");
                self.nextRow();
                for (arr.items) |item| {
                    self.renderValue(item, indent + 2, indent + 2);
                }
                self.emit(indent, "]");
                self.nextRow();
            },
            .string => |s| {
                self.emit(col, "\"");
                self.emit(col + 1, s);
                self.emit(col + 1 + @as(u16, @intCast(@min(s.len, 500))), "\"");
                self.nextRow();
            },
            .integer => |i| {
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{i}) catch "?";
                self.emit(col, s);
                self.nextRow();
            },
            .float => |f| {
                var buf: [64]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{f}) catch "?";
                self.emit(col, s);
                self.nextRow();
            },
            .number_string => |s| {
                self.emit(col, s);
                self.nextRow();
            },
            .bool => |b| {
                self.emit(col, if (b) "true" else "false");
                self.nextRow();
            },
            .null => {
                self.emit(col, "null");
                self.nextRow();
            },
        }
    }
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, sample_json, .{});
    defer parsed.deinit();

    var buffer: [1024]u8 = undefined;
    var tty = try vaxis.Tty.init(&buffer);
    defer tty.deinit();

    var vx = try vaxis.init(alloc, .{});
    defer vx.deinit(alloc, tty.writer());

    var loop: vaxis.Loop(Event) = .{ .tty = &tty, .vaxis = &vx };
    try loop.init();
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), 1 * std.time.ns_per_s);

    while (true) {
        defer tty.writer().flush() catch {};
        const event = loop.nextEvent();
        switch (event) {
            .key_press => |key| {
                if (key.matches('q', .{})) break;
                if (key.matches(vaxis.Key.escape, .{})) break;
                if (key.matches('c', .{ .ctrl = true })) break;
            },
            .winsize => |ws| try vx.resize(alloc, tty.writer(), ws),
        }

        const win = vx.window();
        win.clear();
        var renderer: JsonRenderer = .{ .win = win, .row = 0 };
        renderer.renderValue(parsed.value, 0, 0);
        try vx.render(tty.writer());
    }
}
