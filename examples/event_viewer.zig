const std = @import("std");
const vaxis = @import("vaxis");

const View = enum { list, detail };

const VxEvent = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

const EventEntry = struct {
    line_number: usize,
    name: []const u8,
    timestamp: ?[]const u8,
    parsed: std.json.Parsed(std.json.Value),
};

const timestamp_fields = [_][]const u8{
    "timestamp", "ts", "time", "created_at", "createdAt",
    "updated_at", "updatedAt", "date", "datetime", "at",
};

fn resolveKeyPath(value: std.json.Value, key_path: []const u8) []const u8 {
    var current = value;
    var remaining = key_path;
    while (true) {
        const obj = switch (current) {
            .object => |o| o,
            else => return "(missing)",
        };
        if (std.mem.indexOfScalar(u8, remaining, '.')) |dot| {
            current = obj.get(remaining[0..dot]) orelse return "(missing)";
            remaining = remaining[dot + 1 ..];
        } else {
            const val = obj.get(remaining) orelse return "(missing)";
            return switch (val) {
                .string => |s| s,
                .bool => |b| if (b) "true" else "false",
                .null => "null",
                .number_string => |s| s,
                else => "(complex)",
            };
        }
    }
}

fn detectTimestamp(value: std.json.Value) ?[]const u8 {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };
    for (&timestamp_fields) |field| {
        if (obj.get(field)) |val| {
            switch (val) {
                .string => |s| return s,
                .number_string => |s| return s,
                else => continue,
            }
        }
    }
    return null;
}

fn printUsage() void {
    std.debug.print("Usage: event_viewer <file> [key_path]\n", .{});
    std.debug.print("       event_viewer --file <path> [--key <key_path>]\n", .{});
    std.debug.print("\nDisplays JSONL events as a scrollable card list.\n", .{});
    std.debug.print("key_path defaults to \"name\"\n", .{});
}

const JsonRenderer = struct {
    win: vaxis.Window,
    row: u16,
    scroll: u16,
    height: u16,
    key_fg: vaxis.Cell.Color,
    str_fg: vaxis.Cell.Color,
    num_fg: vaxis.Cell.Color,
    dim_fg: vaxis.Cell.Color,

    fn inView(self: *const JsonRenderer) ?u16 {
        if (self.row >= self.scroll and self.row -| self.scroll < self.height) {
            return self.row - self.scroll;
        }
        return null;
    }

    fn emit(self: *JsonRenderer, col: u16, text: []const u8, fg: vaxis.Cell.Color) void {
        if (self.inView()) |vrow| {
            _ = self.win.printSegment(.{
                .text = text,
                .style = .{ .fg = fg },
            }, .{ .col_offset = col, .row_offset = vrow });
        }
    }

    fn nextRow(self: *JsonRenderer) void {
        self.row +|= 1;
    }

    fn renderValue(self: *JsonRenderer, value: std.json.Value, col: u16, indent: u16) void {
        switch (value) {
            .object => |obj| {
                if (obj.count() == 0) {
                    self.emit(col, "{}", self.dim_fg);
                    self.nextRow();
                    return;
                }
                self.emit(col, "{", self.dim_fg);
                self.nextRow();
                var it = obj.iterator();
                while (it.next()) |entry| {
                    const key = entry.key_ptr.*;
                    const klen: u16 = @intCast(@min(key.len, 500));
                    self.emit(indent + 2, key, self.key_fg);
                    self.emit(indent + 2 + klen, ": ", self.dim_fg);
                    self.renderValue(entry.value_ptr.*, indent + 2 + klen + 2, indent + 2);
                }
                self.emit(indent, "}", self.dim_fg);
                self.nextRow();
            },
            .array => |arr| {
                if (arr.items.len == 0) {
                    self.emit(col, "[]", self.dim_fg);
                    self.nextRow();
                    return;
                }
                self.emit(col, "[", self.dim_fg);
                self.nextRow();
                for (arr.items) |item| {
                    self.renderValue(item, indent + 2, indent + 2);
                }
                self.emit(indent, "]", self.dim_fg);
                self.nextRow();
            },
            .string => |s| {
                self.emit(col, "\"", self.str_fg);
                self.emit(col + 1, s, self.str_fg);
                self.emit(col + 1 + @as(u16, @intCast(@min(s.len, 500))), "\"", self.str_fg);
                self.nextRow();
            },
            .integer => |i| {
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{i}) catch "?";
                self.emit(col, s, self.num_fg);
                self.nextRow();
            },
            .float => |f| {
                var buf: [64]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{f}) catch "?";
                self.emit(col, s, self.num_fg);
                self.nextRow();
            },
            .number_string => |s| {
                self.emit(col, s, self.num_fg);
                self.nextRow();
            },
            .bool => |b| {
                self.emit(col, if (b) "true" else "false", self.num_fg);
                self.nextRow();
            },
            .null => {
                self.emit(col, "null", self.dim_fg);
                self.nextRow();
            },
        }
    }
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Parse CLI args
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    var file_path: ?[]const u8 = null;
    var key_path: []const u8 = "name";

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--file")) {
            i += 1;
            if (i >= args.len) {
                printUsage();
                std.process.exit(1);
            }
            file_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--key")) {
            i += 1;
            if (i >= args.len) {
                printUsage();
                std.process.exit(1);
            }
            key_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            printUsage();
            std.process.exit(0);
        } else if (args[i].len > 0 and args[i][0] == '-') {
            std.debug.print("Unknown flag: {s}\n", .{args[i]});
            printUsage();
            std.process.exit(1);
        } else if (file_path == null) {
            file_path = args[i];
        } else {
            key_path = args[i];
        }
    }

    if (file_path == null) {
        std.debug.print("Error: no file specified\n\n", .{});
        printUsage();
        std.process.exit(1);
    }

    // Read file
    const file = std.fs.cwd().openFile(file_path.?, .{}) catch |err| {
        std.debug.print("Error opening '{s}': {}\n", .{ file_path.?, err });
        std.process.exit(1);
    };
    defer file.close();

    const content = file.readToEndAlloc(alloc, 50 * 1024 * 1024) catch |err| {
        std.debug.print("Error reading file: {}\n", .{err});
        std.process.exit(1);
    };
    defer alloc.free(content);

    // Parse JSONL
    var events: std.ArrayList(EventEntry) = .{};
    defer {
        for (events.items) |*entry| {
            entry.parsed.deinit();
        }
        events.deinit(alloc);
    }

    var skipped: usize = 0;
    var line_num: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        line_num += 1;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        const parsed = std.json.parseFromSlice(std.json.Value, alloc, trimmed, .{}) catch {
            skipped += 1;
            continue;
        };

        events.append(alloc, .{
            .line_number = line_num,
            .name = resolveKeyPath(parsed.value, key_path),
            .timestamp = detectTimestamp(parsed.value),
            .parsed = parsed,
        }) catch {
            parsed.deinit();
            skipped += 1;
            continue;
        };
    }

    // Init terminal
    var buffer: [1024]u8 = undefined;
    var tty = try vaxis.Tty.init(&buffer);
    defer tty.deinit();

    var vx = try vaxis.init(alloc, .{});
    defer vx.deinit(alloc, tty.writer());

    var loop: vaxis.Loop(VxEvent) = .{ .tty = &tty, .vaxis = &vx };
    try loop.init();
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());

    var current_view: View = .list;
    var selected: u16 = 0;
    var list_scroll: u16 = 0;
    var detail_scroll: u16 = 0;
    var detail_total_rows: u16 = 0;

    // Colors
    const header_bg: vaxis.Cell.Color = .{ .rgb = .{ 40, 40, 60 } };
    const sel_border: vaxis.Cell.Color = .{ .rgb = .{ 130, 160, 220 } };
    const card_bg: vaxis.Cell.Color = .{ .rgb = .{ 28, 28, 42 } };
    const card_bg_sel: vaxis.Cell.Color = .{ .rgb = .{ 36, 38, 56 } };
    const accent_fg: vaxis.Cell.Color = .{ .rgb = .{ 130, 160, 220 } };
    const dim_fg: vaxis.Cell.Color = .{ .rgb = .{ 80, 80, 100 } };
    const card_border: vaxis.Cell.Color = .{ .rgb = .{ 50, 50, 70 } };
    const title_fg: vaxis.Cell.Color = .{ .rgb = .{ 200, 200, 220 } };
    const str_val_fg: vaxis.Cell.Color = .{ .rgb = .{ 220, 170, 100 } };
    const num_val_fg: vaxis.Cell.Color = .{ .rgb = .{ 180, 200, 220 } };

    const event_count: u16 = @intCast(@min(events.items.len, std.math.maxInt(u16)));

    while (true) {
        defer tty.writer().flush() catch {};
        const event = loop.nextEvent();

        switch (event) {
            .key_press => |key| {
                if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) break;
                if (key.matches('l', .{ .ctrl = true })) {
                    vx.queueRefresh();
                    continue;
                }

                switch (current_view) {
                    .list => {
                        if (key.matchesAny(&.{ vaxis.Key.up, 'k' }, .{})) selected -|= 1;
                        if (key.matchesAny(&.{ vaxis.Key.down, 'j' }, .{})) {
                            if (event_count > 0 and selected < event_count - 1) selected += 1;
                        }
                        if (key.matches(vaxis.Key.enter, .{})) {
                            if (event_count > 0) {
                                current_view = .detail;
                                detail_scroll = 0;
                            }
                        }
                    },
                    .detail => {
                        if (key.matchesAny(&.{ vaxis.Key.escape, vaxis.Key.backspace }, .{})) {
                            current_view = .list;
                        }
                        if (key.matchesAny(&.{ vaxis.Key.up, 'k' }, .{})) detail_scroll -|= 1;
                        if (key.matchesAny(&.{ vaxis.Key.down, 'j' }, .{})) {
                            if (detail_total_rows > 0 and detail_scroll < detail_total_rows - 1) detail_scroll += 1;
                        }
                    },
                }
            },
            .winsize => |ws| try vx.resize(alloc, tty.writer(), ws),
        }

        // Render
        const win = vx.window();
        win.clear();

        if (win.height < 4 or win.width < 20) {
            try vx.render(tty.writer());
            continue;
        }

        // Header (3 rows: separator, title, separator)
        const header_height: u16 = 3;
        const header = win.child(.{ .width = win.width, .height = header_height });
        header.fill(.{ .style = .{ .bg = header_bg } });

        // Top separator
        {
            var col: u16 = 0;
            while (col < win.width) : (col += 1) {
                header.writeCell(col, 0, .{ .char = .{ .grapheme = "\xe2\x94\x80" }, .style = .{ .fg = dim_fg, .bg = header_bg } });
            }
        }

        switch (current_view) {
            .list => {
                var title_buf: [128]u8 = undefined;
                const title = std.fmt.bufPrint(&title_buf, " Event Viewer ({d} events)", .{events.items.len}) catch " Event Viewer";
                _ = header.printSegment(.{
                    .text = title,
                    .style = .{ .fg = accent_fg, .bg = header_bg, .bold = true },
                }, .{ .row_offset = 1 });

                if (skipped > 0) {
                    var skip_buf: [32]u8 = undefined;
                    const skip_text = std.fmt.bufPrint(&skip_buf, "{d} skipped ", .{skipped}) catch "";
                    const skip_col: u16 = if (win.width > @as(u16, @intCast(skip_text.len)))
                        win.width - @as(u16, @intCast(skip_text.len))
                    else
                        0;
                    _ = header.printSegment(.{
                        .text = skip_text,
                        .style = .{ .fg = dim_fg, .bg = header_bg },
                    }, .{ .col_offset = skip_col, .row_offset = 1 });
                }
            },
            .detail => {
                const entry = &events.items[selected];
                const name_display: []const u8 = if (entry.name.len > 0) entry.name else "(unnamed)";
                _ = header.printSegment(.{
                    .text = name_display,
                    .style = .{ .fg = title_fg, .bg = header_bg, .bold = true },
                }, .{ .col_offset = 1, .row_offset = 1 });

                const back_text = "ESC to go back ";
                const back_col: u16 = if (win.width > @as(u16, @intCast(back_text.len)))
                    win.width - @as(u16, @intCast(back_text.len))
                else
                    0;
                _ = header.printSegment(.{
                    .text = back_text,
                    .style = .{ .fg = dim_fg, .bg = header_bg },
                }, .{ .col_offset = back_col, .row_offset = 1 });
            },
        }

        // Bottom separator
        {
            var col: u16 = 0;
            while (col < win.width) : (col += 1) {
                header.writeCell(col, 2, .{ .char = .{ .grapheme = "\xe2\x94\x80" }, .style = .{ .fg = dim_fg, .bg = header_bg } });
            }
        }

        // Content area
        const content_height = win.height -| header_height;
        if (content_height == 0) {
            try vx.render(tty.writer());
            continue;
        }
        const content_win = win.child(.{
            .y_off = @as(i17, @intCast(header_height)),
            .width = win.width,
            .height = content_height,
        });

        switch (current_view) {
            .list => {
                if (event_count == 0) {
                    const msg = "No events found";
                    const cx: u16 = if (win.width > @as(u16, @intCast(msg.len)))
                        (win.width - @as(u16, @intCast(msg.len))) / 2
                    else
                        0;
                    _ = content_win.printSegment(.{
                        .text = msg,
                        .style = .{ .fg = dim_fg },
                    }, .{ .col_offset = cx, .row_offset = content_height / 2 });
                } else {
                    if (selected >= event_count) selected = event_count - 1;

                    const card_height: u16 = 4;
                    const card_gap: u16 = 1;
                    const card_stride: u16 = card_height + card_gap;
                    const card_margin: u16 = 2;
                    const top_pad: u16 = 1;
                    const bottom_pad: u16 = 1;
                    const card_width: u16 = if (win.width > card_margin * 2 + 4) win.width - card_margin * 2 else win.width;

                    // Scroll so selected card is always visible
                    const sel_top = @as(u32, selected) * card_stride + top_pad;
                    const sel_bottom = sel_top + card_height + bottom_pad;
                    if (sel_top < list_scroll) {
                        list_scroll = @intCast(sel_top -| top_pad);
                    } else if (sel_bottom > @as(u32, list_scroll) + content_height) {
                        list_scroll = @intCast(sel_bottom -| content_height);
                    }

                    for (events.items, 0..) |entry, idx| {
                        if (idx > std.math.maxInt(u16)) break;
                        const job_idx: u16 = @intCast(idx);
                        const card_top_abs = @as(i32, job_idx) * card_stride + top_pad;
                        const card_top = card_top_abs - @as(i32, list_scroll);

                        if (card_top < 0) continue;
                        if (card_top >= content_height) break;

                        const is_selected = job_idx == selected;
                        const bg = if (is_selected) card_bg_sel else card_bg;
                        const border_color = if (is_selected) sel_border else card_border;

                        const card = content_win.child(.{
                            .x_off = @as(i17, @intCast(card_margin)),
                            .y_off = @as(i17, @intCast(card_top)),
                            .width = card_width,
                            .height = card_height,
                        });
                        card.fill(.{ .style = .{ .bg = bg } });

                        // Corners
                        card.writeCell(0, 0, .{ .char = .{ .grapheme = "\xe2\x94\x8c" }, .style = .{ .fg = border_color, .bg = bg } }); // "┌"
                        card.writeCell(card_width -| 1, 0, .{ .char = .{ .grapheme = "\xe2\x94\x90" }, .style = .{ .fg = border_color, .bg = bg } }); // "┐"
                        card.writeCell(0, card_height - 1, .{ .char = .{ .grapheme = "\xe2\x94\x94" }, .style = .{ .fg = border_color, .bg = bg } }); // "└"
                        card.writeCell(card_width -| 1, card_height - 1, .{ .char = .{ .grapheme = "\xe2\x94\x98" }, .style = .{ .fg = border_color, .bg = bg } }); // "┘"

                        // Horizontal borders
                        {
                            var col: u16 = 1;
                            while (col < card_width -| 1) : (col += 1) {
                                card.writeCell(col, 0, .{ .char = .{ .grapheme = "\xe2\x94\x80" }, .style = .{ .fg = border_color, .bg = bg } }); // "─"
                                card.writeCell(col, card_height - 1, .{ .char = .{ .grapheme = "\xe2\x94\x80" }, .style = .{ .fg = border_color, .bg = bg } }); // "─"
                            }
                        }

                        // Vertical borders
                        {
                            var row: u16 = 1;
                            while (row < card_height - 1) : (row += 1) {
                                card.writeCell(0, row, .{ .char = .{ .grapheme = "\xe2\x94\x82" }, .style = .{ .fg = border_color, .bg = bg } }); // "│"
                                card.writeCell(card_width -| 1, row, .{ .char = .{ .grapheme = "\xe2\x94\x82" }, .style = .{ .fg = border_color, .bg = bg } }); // "│"
                            }
                        }

                        // Selected card: accent left border bar
                        if (is_selected) {
                            card.writeCell(0, 0, .{ .char = .{ .grapheme = "\xe2\x94\x8c" }, .style = .{ .fg = sel_border, .bg = bg } }); // "┌"
                            card.writeCell(0, card_height - 1, .{ .char = .{ .grapheme = "\xe2\x94\x94" }, .style = .{ .fg = sel_border, .bg = bg } }); // "└"
                            var row: u16 = 1;
                            while (row < card_height - 1) : (row += 1) {
                                card.writeCell(0, row, .{ .char = .{ .grapheme = "\xe2\x96\x90" }, .style = .{ .fg = sel_border, .bg = bg } }); // "▐"
                            }
                        }

                        // Row 1: name
                        const name_display: []const u8 = if (entry.name.len > 0) entry.name else "(unnamed)";
                        _ = card.printSegment(.{
                            .text = name_display,
                            .style = .{ .fg = if (is_selected) title_fg else accent_fg, .bg = bg, .bold = true },
                        }, .{ .col_offset = 2, .row_offset = 1 });

                        // Row 2: Line N (left) + timestamp (right)
                        var line_buf: [32]u8 = undefined;
                        const line_text = std.fmt.bufPrint(&line_buf, "Line {d}", .{entry.line_number}) catch "?";
                        _ = card.printSegment(.{
                            .text = line_text,
                            .style = .{ .fg = dim_fg, .bg = bg },
                        }, .{ .col_offset = 2, .row_offset = 2 });

                        if (entry.timestamp) |ts| {
                            const ts_len: u16 = @intCast(@min(ts.len, card_width));
                            const ts_col: u16 = if (card_width > ts_len + 2) card_width - ts_len - 2 else 2;
                            _ = card.printSegment(.{
                                .text = ts,
                                .style = .{ .fg = dim_fg, .bg = bg },
                            }, .{ .col_offset = ts_col, .row_offset = 2 });
                        }
                    }
                }
            },
            .detail => {
                const entry = &events.items[selected];
                var renderer: JsonRenderer = .{
                    .win = content_win,
                    .row = 0,
                    .scroll = detail_scroll,
                    .height = content_height,
                    .key_fg = accent_fg,
                    .str_fg = str_val_fg,
                    .num_fg = num_val_fg,
                    .dim_fg = dim_fg,
                };
                renderer.renderValue(entry.parsed.value, 2, 2);
                detail_total_rows = renderer.row;
            },
        }

        try vx.render(tty.writer());
    }
}
