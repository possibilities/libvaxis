const std = @import("std");
const vaxis = @import("vaxis");

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    jobs_updated,
};

const ConnectionStatus = enum {
    connecting,
    connected,
    disconnected,
    err,
};

const Job = struct {
    title: []const u8,
    session_id: []const u8,
    pid: []const u8,
    tmux_session: []const u8,
    prise_session: []const u8,
};

const SharedState = struct {
    mutex: std.Thread.Mutex = .{},
    jobs: std.StringArrayHashMapUnmanaged(Job) = .{},
    status: ConnectionStatus = .connecting,
    error_msg: []const u8 = "",
    alloc: std.mem.Allocator,

    fn deinit(self: *SharedState) void {
        var it = self.jobs.iterator();
        while (it.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            freeJob(self.alloc, entry.value_ptr.*);
        }
        self.jobs.deinit(self.alloc);
        if (self.error_msg.len > 0) self.alloc.free(self.error_msg);
    }

    fn freeJob(alloc: std.mem.Allocator, job: Job) void {
        alloc.free(job.title);
        alloc.free(job.session_id);
        alloc.free(job.pid);
        alloc.free(job.tmux_session);
        alloc.free(job.prise_session);
    }

    fn dupeJob(alloc: std.mem.Allocator, title: []const u8, session_id: []const u8, pid: []const u8, tmux_session: []const u8, prise_session: []const u8) !Job {
        const t = try alloc.dupe(u8, title);
        errdefer alloc.free(t);
        const s = try alloc.dupe(u8, session_id);
        errdefer alloc.free(s);
        const p = try alloc.dupe(u8, pid);
        errdefer alloc.free(p);
        const tm = try alloc.dupe(u8, tmux_session);
        errdefer alloc.free(tm);
        const pr = try alloc.dupe(u8, prise_session);
        errdefer alloc.free(pr);
        return .{ .title = t, .session_id = s, .pid = p, .tmux_session = tm, .prise_session = pr };
    }

    fn clearJobs(self: *SharedState) void {
        var it = self.jobs.iterator();
        while (it.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            freeJob(self.alloc, entry.value_ptr.*);
        }
        self.jobs.clearRetainingCapacity();
    }

    fn setError(self: *SharedState, msg: []const u8) void {
        if (self.error_msg.len > 0) self.alloc.free(self.error_msg);
        self.error_msg = self.alloc.dupe(u8, msg) catch "";
        self.status = .err;
    }
};

fn getStr(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    const val = obj.get(key) orelse return "";
    return switch (val) {
        .string => |s| s,
        .integer => |i| blk: {
            _ = i;
            break :blk "<int>";
        },
        else => "",
    };
}

fn socketReader(state: *SharedState, loop: *vaxis.Loop(Event)) void {
    const home = std.posix.getenv("HOME") orelse "/tmp";
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.local/share/jobctl/watch-jobs.sock", .{home}) catch {
        state.mutex.lock();
        state.setError("path too long");
        state.mutex.unlock();
        loop.postEvent(.jobs_updated);
        return;
    };

    const stream = std.net.connectUnixSocket(path) catch {
        state.mutex.lock();
        state.setError("cannot connect to watch-jobs.sock");
        state.status = .disconnected;
        state.mutex.unlock();
        loop.postEvent(.jobs_updated);
        return;
    };
    defer stream.close();

    {
        state.mutex.lock();
        state.status = .connected;
        state.mutex.unlock();
        loop.postEvent(.jobs_updated);
    }

    var buf: [65536]u8 = undefined;
    var leftover: std.ArrayListUnmanaged(u8) = .{};
    defer leftover.deinit(state.alloc);

    while (true) {
        const n = stream.read(&buf) catch {
            state.mutex.lock();
            state.setError("read error");
            state.mutex.unlock();
            loop.postEvent(.jobs_updated);
            return;
        };
        if (n == 0) {
            state.mutex.lock();
            state.status = .disconnected;
            state.mutex.unlock();
            loop.postEvent(.jobs_updated);
            return;
        }

        leftover.appendSlice(state.alloc, buf[0..n]) catch return;

        while (std.mem.indexOfScalar(u8, leftover.items, '\n')) |nl| {
            const line = leftover.items[0..nl];
            if (line.len > 0) {
                processLine(state, line) catch {};
                loop.postEvent(.jobs_updated);
            }
            // Remove processed line + newline
            const remaining = leftover.items[nl + 1 ..];
            std.mem.copyForwards(u8, leftover.items[0..remaining.len], remaining);
            leftover.items.len = remaining.len;
        }
    }
}

fn processLine(state: *SharedState, line: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, state.alloc, line, .{}) catch return;
    defer parsed.deinit();

    const root = parsed.value.object;
    const msg_type = getStr(root, "type");

    if (std.mem.eql(u8, msg_type, "snapshot")) {
        const state_val = root.get("state") orelse return;
        if (state_val != .object) return;
        const state_obj = state_val.object;

        state.mutex.lock();
        defer state.mutex.unlock();

        state.clearJobs();

        var it = state_obj.iterator();
        while (it.next()) |entry| {
            const job_id = entry.key_ptr.*;
            const job_val = entry.value_ptr.*;
            if (job_val != .object) continue;
            const obj = job_val.object;

            const key = state.alloc.dupe(u8, job_id) catch continue;
            const job = SharedState.dupeJob(
                state.alloc,
                getStr(obj, "title"),
                getStr(obj, "session_id"),
                getStr(obj, "pid"),
                getStr(obj, "tmux_session"),
                getStr(obj, "prise_session"),
            ) catch {
                state.alloc.free(key);
                continue;
            };
            state.jobs.put(state.alloc, key, job) catch {
                state.alloc.free(key);
                SharedState.freeJob(state.alloc, job);
                continue;
            };
        }
    } else if (std.mem.eql(u8, msg_type, "event")) {
        const event_type = getStr(root, "event");
        const job_id = getStr(root, "job_id");

        state.mutex.lock();
        defer state.mutex.unlock();

        if (std.mem.eql(u8, event_type, "job_added")) {
            const name = getStr(root, "name");
            const key = state.alloc.dupe(u8, job_id) catch return;
            const job = SharedState.dupeJob(state.alloc, name, "", "", "", "") catch {
                state.alloc.free(key);
                return;
            };
            state.jobs.put(state.alloc, key, job) catch {
                state.alloc.free(key);
                SharedState.freeJob(state.alloc, job);
            };
        } else if (std.mem.eql(u8, event_type, "job_removed")) {
            if (state.jobs.fetchSwapRemove(job_id)) |kv| {
                state.alloc.free(kv.key);
                SharedState.freeJob(state.alloc, kv.value);
            }
        } else if (std.mem.eql(u8, event_type, "title_changed")) {
            const new_title = getStr(root, "new_title");
            if (state.jobs.getPtr(job_id)) |job| {
                const old = job.title;
                job.title = state.alloc.dupe(u8, new_title) catch return;
                state.alloc.free(old);
            }
        } else if (std.mem.eql(u8, event_type, "name_changed")) {
            const new_name = getStr(root, "new_name");
            if (state.jobs.getPtr(job_id)) |job| {
                const old = job.title;
                job.title = state.alloc.dupe(u8, new_name) catch return;
                state.alloc.free(old);
            }
        }
    }
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

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

    var state: SharedState = .{ .alloc = alloc };
    defer state.deinit();

    const reader_thread = try std.Thread.spawn(.{}, socketReader, .{ &state, &loop });
    reader_thread.detach();

    var selected: u16 = 0;
    var scroll_offset: u16 = 0;

    // Colors
    const header_bg: vaxis.Cell.Color = .{ .rgb = .{ 40, 40, 60 } };
    const sel_border: vaxis.Cell.Color = .{ .rgb = .{ 130, 160, 220 } };
    const card_bg: vaxis.Cell.Color = .{ .rgb = .{ 28, 28, 42 } };
    const card_bg_sel: vaxis.Cell.Color = .{ .rgb = .{ 36, 38, 56 } };
    const title_fg: vaxis.Cell.Color = .{ .rgb = .{ 200, 200, 220 } };
    const project_fg: vaxis.Cell.Color = .{ .rgb = .{ 130, 160, 220 } };
    const dim_fg: vaxis.Cell.Color = .{ .rgb = .{ 80, 80, 100 } };
    const card_border: vaxis.Cell.Color = .{ .rgb = .{ 50, 50, 70 } };
    const status_ok: vaxis.Cell.Color = .{ .rgb = .{ 80, 200, 120 } };
    const status_warn: vaxis.Cell.Color = .{ .rgb = .{ 200, 180, 60 } };
    const status_bad: vaxis.Cell.Color = .{ .rgb = .{ 200, 80, 80 } };
    const footer_bg: vaxis.Cell.Color = .{ .rgb = .{ 30, 30, 45 } };
    const footer_fg: vaxis.Cell.Color = .{ .rgb = .{ 120, 120, 150 } };
    const accent_fg: vaxis.Cell.Color = .{ .rgb = .{ 130, 160, 220 } };

    while (true) {
        defer tty.writer().flush() catch {};
        const event = loop.nextEvent();

        switch (event) {
            .key_press => |key| {
                if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) break;
                if (key.matchesAny(&.{ vaxis.Key.up, 'k' }, .{})) selected -|= 1;
                if (key.matchesAny(&.{ vaxis.Key.down, 'j' }, .{})) selected +|= 1;
                if (key.matches('l', .{ .ctrl = true })) vx.queueRefresh();
            },
            .winsize => |ws| try vx.resize(alloc, tty.writer(), ws),
            .jobs_updated => {},
        }

        // Render
        const win = vx.window();
        win.clear();

        if (win.height < 4 or win.width < 20) {
            try vx.render(tty.writer());
            continue;
        }

        // Header (3 rows: title centered in rows 0-1, separator at row 2)
        const header_height: u16 = 3;
        const header = win.child(.{ .width = win.width, .height = header_height });
        header.fill(.{ .style = .{ .bg = header_bg } });
        _ = header.printSegment(.{
            .text = " Job Dashboard",
            .style = .{ .fg = accent_fg, .bg = header_bg, .bold = true },
        }, .{ .row_offset = 0 });

        // Status indicator
        state.mutex.lock();
        const status = state.status;
        const err_msg = state.error_msg;
        const job_count = state.jobs.count();
        state.mutex.unlock();

        const status_text: []const u8 = switch (status) {
            .connecting => "connecting...",
            .connected => "connected",
            .disconnected => "disconnected",
            .err => err_msg,
        };
        const status_color: vaxis.Cell.Color = switch (status) {
            .connecting => status_warn,
            .connected => status_ok,
            .disconnected => status_bad,
            .err => status_bad,
        };

        const dot = " \xe2\x97\x8f "; // " ● "
        const status_col: u16 = if (win.width > 16 + @as(u16, @intCast(status_text.len)) + 3)
            win.width - @as(u16, @intCast(status_text.len)) - 3
        else
            16;
        _ = header.printSegment(.{ .text = dot, .style = .{ .fg = status_color, .bg = header_bg } }, .{ .col_offset = status_col, .row_offset = 0 });
        _ = header.printSegment(.{ .text = status_text, .style = .{ .fg = status_color, .bg = header_bg } }, .{ .col_offset = status_col + 3, .row_offset = 0 });

        // Separator line at row 2
        {
            var col: u16 = 0;
            while (col < win.width) : (col += 1) {
                header.writeCell(col, 2, .{ .char = .{ .grapheme = "\xe2\x94\x80" }, .style = .{ .fg = dim_fg, .bg = header_bg } }); // "─"
            }
        }

        // Footer (1 row)
        const footer = win.child(.{
            .y_off = @as(i17, @intCast(win.height - 1)),
            .width = win.width,
            .height = 1,
        });
        footer.fill(.{ .style = .{ .bg = footer_bg } });
        _ = footer.printSegment(.{
            .text = " q quit  j/k navigate",
            .style = .{ .fg = footer_fg, .bg = footer_bg },
        }, .{});

        // Job count on the right side of footer
        var count_buf: [32]u8 = undefined;
        const count_str = std.fmt.bufPrint(&count_buf, "{d} job{s} ", .{ job_count, if (job_count != 1) "s" else "" }) catch "? jobs ";
        const count_col: u16 = if (win.width > @as(u16, @intCast(count_str.len)))
            win.width - @as(u16, @intCast(count_str.len))
        else
            0;
        _ = footer.printSegment(.{
            .text = count_str,
            .style = .{ .fg = dim_fg, .bg = footer_bg },
        }, .{ .col_offset = count_col });

        // Job list area (below header, above footer)
        const list_height = win.height -| (header_height + 1);
        if (list_height == 0) {
            try vx.render(tty.writer());
            continue;
        }
        const list = win.child(.{
            .y_off = @as(i17, @intCast(header_height)),
            .width = win.width,
            .height = list_height,
        });

        state.mutex.lock();
        const count: u16 = @intCast(state.jobs.count());

        // Clamp selection
        if (count > 0 and selected >= count) selected = count - 1;

        if (count == 0) {
            state.mutex.unlock();
            const empty_msg: []const u8 = switch (status) {
                .connecting => "Connecting to watch-jobs socket...",
                .connected => "No jobs running",
                .disconnected => "Socket disconnected",
                .err => err_msg,
            };
            const center_col: u16 = if (win.width > @as(u16, @intCast(empty_msg.len)))
                (win.width - @as(u16, @intCast(empty_msg.len))) / 2
            else
                0;
            const center_row: u16 = list_height / 2;
            _ = list.printSegment(.{
                .text = empty_msg,
                .style = .{ .fg = dim_fg },
            }, .{ .col_offset = center_col, .row_offset = center_row });
        } else {
            const card_height: u16 = 4; // border-top + project + title + border-bottom
            const card_gap: u16 = 1;
            const card_stride: u16 = card_height + card_gap;
            const card_margin: u16 = 2; // left/right margin
            const top_pad: u16 = 1; // space above first card
            const bottom_pad: u16 = 1; // space below last card
            const card_width: u16 = if (win.width > card_margin * 2 + 4) win.width - card_margin * 2 else win.width;

            // Scroll so selected card is always visible
            const sel_top = @as(u32, selected) * card_stride + top_pad;
            const sel_bottom = sel_top + card_height + bottom_pad;
            if (sel_top < scroll_offset) {
                scroll_offset = @intCast(sel_top -| top_pad);
            } else if (sel_bottom > @as(u32, scroll_offset) + list_height) {
                scroll_offset = @intCast(sel_bottom -| list_height);
            }

            var job_idx: u16 = 0;
            var it = state.jobs.iterator();
            while (it.next()) |entry| {
                const card_top_abs = @as(i32, job_idx) * card_stride + top_pad;
                const card_top = card_top_abs - @as(i32, scroll_offset);

                // Skip cards above viewport (prevents overlapping header)
                if (card_top < 0) {
                    job_idx += 1;
                    continue;
                }
                // Stop if card starts below viewport
                if (card_top >= list_height) break;

                const job = entry.value_ptr.*;
                const is_selected = job_idx == selected;
                const bg = if (is_selected) card_bg_sel else card_bg;
                const border_color = if (is_selected) sel_border else card_border;

                const card = list.child(.{
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

                // Top and bottom borders (between corners)
                {
                    var col: u16 = 1;
                    while (col < card_width -| 1) : (col += 1) {
                        card.writeCell(col, 0, .{ .char = .{ .grapheme = "\xe2\x94\x80" }, .style = .{ .fg = border_color, .bg = bg } }); // "─"
                        card.writeCell(col, card_height - 1, .{ .char = .{ .grapheme = "\xe2\x94\x80" }, .style = .{ .fg = border_color, .bg = bg } }); // "─"
                    }
                }

                // Left and right vertical borders
                {
                    var row: u16 = 1;
                    while (row < card_height - 1) : (row += 1) {
                        card.writeCell(0, row, .{ .char = .{ .grapheme = "\xe2\x94\x82" }, .style = .{ .fg = border_color, .bg = bg } }); // "│"
                        card.writeCell(card_width -| 1, row, .{ .char = .{ .grapheme = "\xe2\x94\x82" }, .style = .{ .fg = border_color, .bg = bg } }); // "│"
                    }
                }

                // Selected card: accent bar overrides left side
                if (is_selected) {
                    card.writeCell(0, 0, .{ .char = .{ .grapheme = "\xe2\x94\x8c" }, .style = .{ .fg = sel_border, .bg = bg } }); // "┌"
                    card.writeCell(0, card_height - 1, .{ .char = .{ .grapheme = "\xe2\x94\x94" }, .style = .{ .fg = sel_border, .bg = bg } }); // "└"
                    var row: u16 = 1;
                    while (row < card_height - 1) : (row += 1) {
                        card.writeCell(0, row, .{ .char = .{ .grapheme = "\xe2\x96\x90" }, .style = .{ .fg = sel_border, .bg = bg } }); // "▐"
                    }
                }

                // Row 1: project name
                const project_name: []const u8 = if (job.prise_session.len > 0)
                    job.prise_session
                else if (job.tmux_session.len > 0)
                    job.tmux_session
                else
                    "(no project)";
                _ = card.printSegment(.{
                    .text = project_name,
                    .style = .{ .fg = project_fg, .bg = bg, .bold = true },
                }, .{ .col_offset = 2, .row_offset = 1 });

                // Row 2: title
                const title_display: []const u8 = if (job.title.len > 0) job.title else "(untitled)";
                _ = card.printSegment(.{
                    .text = title_display,
                    .style = .{ .fg = if (is_selected) title_fg else dim_fg, .bg = bg },
                }, .{ .col_offset = 2, .row_offset = 2 });

                job_idx += 1;
            }
            state.mutex.unlock();
        }

        try vx.render(tty.writer());
    }
}
