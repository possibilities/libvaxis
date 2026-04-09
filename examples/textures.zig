const std = @import("std");
const vaxis = @import("vaxis");

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

// ── Colors ──────────────────────────────────────────────────────────────

const global_bg: vaxis.Cell.Color = .{ .rgb = .{ 16, 16, 24 } };
const card_border: vaxis.Cell.Color = .{ .rgb = .{ 50, 50, 70 } };
const label_fg: vaxis.Cell.Color = .{ .rgb = .{ 160, 160, 180 } };
const tag_fg: vaxis.Cell.Color = .{ .rgb = .{ 90, 90, 110 } };
const header_fg: vaxis.Cell.Color = .{ .rgb = .{ 130, 160, 220 } };

// ── Math Utilities ──────────────────────────────────────────────────────

fn hash2d(x: i32, y: i32) u8 {
    // Simple deterministic hash
    const a: u32 = @bitCast(x *% 374761393);
    const b: u32 = @bitCast(y *% 668265263);
    var h = a +% b;
    h = (h ^ (h >> 13)) *% 1274126177;
    h = h ^ (h >> 16);
    return @truncate(h);
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn smoothstep(t: f32) f32 {
    return t * t * (3.0 - 2.0 * t);
}

fn valueNoise2d(x: f32, y: f32) f32 {
    const ix: i32 = @intFromFloat(@floor(x));
    const iy: i32 = @intFromFloat(@floor(y));
    const fx = x - @floor(x);
    const fy = y - @floor(y);

    const sx = smoothstep(fx);
    const sy = smoothstep(fy);

    const n00 = @as(f32, @floatFromInt(hash2d(ix, iy))) / 255.0;
    const n10 = @as(f32, @floatFromInt(hash2d(ix + 1, iy))) / 255.0;
    const n01 = @as(f32, @floatFromInt(hash2d(ix, iy + 1))) / 255.0;
    const n11 = @as(f32, @floatFromInt(hash2d(ix + 1, iy + 1))) / 255.0;

    const top = lerp(n00, n10, sx);
    const bot = lerp(n01, n11, sx);
    return lerp(top, bot, sy);
}

fn hsvToRgb(h: f32, s: f32, v: f32) [3]u8 {
    const c = v * s;
    const hp = @mod(h, 360.0) / 60.0;
    const x = c * (1.0 - @abs(@mod(hp, 2.0) - 1.0));
    const m = v - c;

    var r: f32 = 0;
    var g: f32 = 0;
    var b: f32 = 0;

    if (hp < 1) {
        r = c;
        g = x;
    } else if (hp < 2) {
        r = x;
        g = c;
    } else if (hp < 3) {
        g = c;
        b = x;
    } else if (hp < 4) {
        g = x;
        b = c;
    } else if (hp < 5) {
        r = x;
        b = c;
    } else {
        r = c;
        b = x;
    }

    return .{
        @intFromFloat((r + m) * 255.0),
        @intFromFloat((g + m) * 255.0),
        @intFromFloat((b + m) * 255.0),
    };
}

// ── Braille Encoding ────────────────────────────────────────────────────

// Braille codepoints U+2800..U+28FF. Each of the 256 patterns encodes as
// 3 UTF-8 bytes: 0xE2, 0xA0|(n>>6), 0x80|(n&0x3F)
const braille_table: [256][3]u8 = blk: {
    var table: [256][3]u8 = undefined;
    for (0..256) |i| {
        table[i] = .{
            0xE2,
            0xA0 | @as(u8, @truncate(i >> 6)),
            0x80 | @as(u8, @truncate(i & 0x3F)),
        };
    }
    break :blk table;
};

fn brailleEncode(dots: u8) [3]u8 {
    return braille_table[dots];
}

// ── Texture Descriptors ─────────────────────────────────────────────────

const Technique = enum { half_block, braille, char_color };

const Texture = struct {
    name: []const u8,
    technique: Technique,
    render: *const fn (win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void,
};

const textures = [_]Texture{
    .{ .name = "Herringbone", .technique = .char_color, .render = renderHerringboneGrey },
    .{ .name = "Zigzag", .technique = .char_color, .render = renderZigzag },
    .{ .name = "Chevron", .technique = .char_color, .render = renderChevron },
    .{ .name = "Diamond", .technique = .char_color, .render = renderDiamond },
    .{ .name = "Parquet", .technique = .char_color, .render = renderParquet },
    .{ .name = "Ripple", .technique = .char_color, .render = renderRipple },
    .{ .name = "Pinstripe", .technique = .char_color, .render = renderPinstripe },
    .{ .name = "Tumble", .technique = .char_color, .render = renderTumble },
    .{ .name = "Shingle", .technique = .char_color, .render = renderShingle },
    .{ .name = "Noise Weave", .technique = .char_color, .render = renderNoiseWeave },
    .{ .name = "Grid Weave", .technique = .char_color, .render = renderGridWeave },
    .{ .name = "Grid Shingle", .technique = .char_color, .render = renderGridShingle },
    .{ .name = "Grid Chevron", .technique = .char_color, .render = renderGridChevron },
    .{ .name = "Grid Parquet", .technique = .char_color, .render = renderGridParquet },
};

fn techniqueTag(t: Technique) []const u8 {
    return switch (t) {
        .half_block => "(half-block)",
        .braille => "(braille)",
        .char_color => "(char+color)",
    };
}

// ── Half-block Texture Renderers ────────────────────────────────────────

fn renderSimplexNoise(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    const scale: f32 = 0.15;
    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            const top_v = valueNoise2d(@as(f32, @floatFromInt(col)) * scale, @as(f32, @floatFromInt(row * 2)) * scale);
            const bot_v = valueNoise2d(@as(f32, @floatFromInt(col)) * scale, @as(f32, @floatFromInt(row * 2 + 1)) * scale);

            const top_rgb = tealGradient(top_v);
            const bot_rgb = tealGradient(bot_v);

            win.writeCell(col, row, .{
                .char = .{ .grapheme = "\xe2\x96\x80", .width = 1 }, // ▀
                .style = .{ .fg = .{ .rgb = top_rgb }, .bg = .{ .rgb = bot_rgb } },
            });
        }
    }
}

fn tealGradient(t: f32) [3]u8 {
    return .{
        @intFromFloat(lerp(16, 40, t)),
        @intFromFloat(lerp(16, 180, t)),
        @intFromFloat(lerp(24, 180, t)),
    };
}

fn renderPlasma(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    const s: f32 = 4.0;
    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            const top_hue = plasmaValue(@as(f32, @floatFromInt(col)), @as(f32, @floatFromInt(row * 2)), s);
            const bot_hue = plasmaValue(@as(f32, @floatFromInt(col)), @as(f32, @floatFromInt(row * 2 + 1)), s);

            win.writeCell(col, row, .{
                .char = .{ .grapheme = "\xe2\x96\x80", .width = 1 },
                .style = .{
                    .fg = .{ .rgb = hsvToRgb(top_hue, 0.8, 0.9) },
                    .bg = .{ .rgb = hsvToRgb(bot_hue, 0.8, 0.9) },
                },
            });
        }
    }
}

fn plasmaValue(x: f32, y: f32, s: f32) f32 {
    const v = @sin(x / s) + @sin(y / s) + @sin((x + y) / s) + @sin(@sqrt(x * x + y * y) / s);
    // Map [-4, 4] to [0, 360]
    return (v + 4.0) / 8.0 * 360.0;
}

fn renderRadialGradient(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    const cx = @as(f32, @floatFromInt(w)) / 2.0;
    const cy = @as(f32, @floatFromInt(h));
    const max_dist = @sqrt(cx * cx + cy * cy);

    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            const top_t = radialDist(col, row * 2, cx, cy, max_dist);
            const bot_t = radialDist(col, row * 2 + 1, cx, cy, max_dist);

            win.writeCell(col, row, .{
                .char = .{ .grapheme = "\xe2\x96\x80", .width = 1 },
                .style = .{
                    .fg = .{ .rgb = amberGradient(top_t) },
                    .bg = .{ .rgb = amberGradient(bot_t) },
                },
            });
        }
    }
}

fn radialDist(col: u16, py: u16, cx: f32, cy: f32, max_dist: f32) f32 {
    const dx = @as(f32, @floatFromInt(col)) - cx;
    const dy = @as(f32, @floatFromInt(py)) - cy;
    const d = @sqrt(dx * dx + dy * dy) / max_dist;
    return @min(d, 1.0);
}

fn amberGradient(t: f32) [3]u8 {
    return .{
        @intFromFloat(lerp(16, 220, t)),
        @intFromFloat(lerp(16, 160, t)),
        @intFromFloat(lerp(24, 60, t)),
    };
}

fn renderMoire(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    const cx1 = @as(f32, @floatFromInt(w)) * 0.35;
    const cy1 = @as(f32, @floatFromInt(h));
    const cx2 = @as(f32, @floatFromInt(w)) * 0.65;
    const cy2 = @as(f32, @floatFromInt(h)) * 0.3;
    const freq: f32 = 1.8;

    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            const top_v = moireValue(col, row * 2, cx1, cy1, cx2, cy2, freq);
            const bot_v = moireValue(col, row * 2 + 1, cx1, cy1, cx2, cy2, freq);

            win.writeCell(col, row, .{
                .char = .{ .grapheme = "\xe2\x96\x80", .width = 1 },
                .style = .{
                    .fg = .{ .rgb = moireColor(top_v) },
                    .bg = .{ .rgb = moireColor(bot_v) },
                },
            });
        }
    }
}

fn moireValue(col: u16, py: u16, cx1: f32, cy1: f32, cx2: f32, cy2: f32, freq: f32) f32 {
    const x = @as(f32, @floatFromInt(col));
    const y = @as(f32, @floatFromInt(py));
    const dx1 = x - cx1;
    const dy1 = y - cy1;
    const dx2 = x - cx2;
    const dy2 = y - cy2;
    const d1 = @sqrt(dx1 * dx1 + dy1 * dy1);
    const d2 = @sqrt(dx2 * dx2 + dy2 * dy2);
    return (@sin(d1 * freq) + @sin(d2 * freq) + 2.0) / 4.0;
}

fn moireColor(t: f32) [3]u8 {
    // Purple → cyan interpolation
    return .{
        @intFromFloat(lerp(160, 80, t) * t + lerp(16, 16, t) * (1.0 - t)),
        @intFromFloat(lerp(100, 200, t)),
        @intFromFloat(lerp(220, 200, t)),
    };
}

// ── Braille Texture Renderers ───────────────────────────────────────────

// Braille dot layout per cell (2 cols × 4 rows):
//   bit0  bit3
//   bit1  bit4
//   bit2  bit5
//   bit6  bit7

fn brailleDotBit(dx: u3, dy: u3) u8 {
    // dx: 0 or 1, dy: 0..3
    const bits = [2][4]u3{
        .{ 0, 1, 2, 6 }, // left column
        .{ 3, 4, 5, 7 }, // right column
    };
    return @as(u8, 1) << bits[dx][dy];
}

fn renderCrosshatch(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    const spacing: i32 = 6;
    const thickness: i32 = 2;
    const color: vaxis.Cell.Color = .{ .rgb = .{ 200, 140, 100 } };

    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            var dots: u8 = 0;
            var dy: u3 = 0;
            while (dy < 4) : (dy += 1) {
                var dx: u3 = 0;
                while (dx < 2) : (dx += 1) {
                    const px: i32 = @as(i32, col) * 2 + dx;
                    const py: i32 = @as(i32, row) * 4 + dy;
                    const diag1 = @mod(px + py, spacing);
                    const diag2 = @mod(px - py + spacing * 16, spacing);
                    if (diag1 < thickness or diag2 < thickness) {
                        dots |= brailleDotBit(dx, dy);
                    }
                }
            }
            const encoded = brailleEncode(dots);
            win.writeCell(col, row, .{
                .char = .{ .grapheme = &encoded, .width = 1 },
                .style = .{ .fg = color, .bg = global_bg },
            });
        }
    }
}

fn renderConcentricRings(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    const cx = @as(f32, @floatFromInt(w));
    const cy = @as(f32, @floatFromInt(h)) * 2.0;
    const color: vaxis.Cell.Color = .{ .rgb = .{ 100, 200, 160 } };

    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            var dots: u8 = 0;
            var dy: u3 = 0;
            while (dy < 4) : (dy += 1) {
                var dx: u3 = 0;
                while (dx < 2) : (dx += 1) {
                    const px = @as(f32, @floatFromInt(@as(i32, col) * 2 + dx)) - cx;
                    const py = @as(f32, @floatFromInt(@as(i32, row) * 4 + dy)) - cy;
                    const dist = @sqrt(px * px + py * py);
                    if (@as(u32, @intFromFloat(@floor(dist / 2.5))) % 2 == 0) {
                        dots |= brailleDotBit(dx, dy);
                    }
                }
            }
            const encoded = brailleEncode(dots);
            win.writeCell(col, row, .{
                .char = .{ .grapheme = &encoded, .width = 1 },
                .style = .{ .fg = color, .bg = global_bg },
            });
        }
    }
}

fn renderDiamondLattice(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    const spacing: i32 = 8;
    const threshold: i32 = 3;
    const color: vaxis.Cell.Color = .{ .rgb = .{ 180, 160, 100 } };
    const cx: i32 = @as(i32, w);
    const cy: i32 = @as(i32, h) * 2;

    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            var dots: u8 = 0;
            var dy: u3 = 0;
            while (dy < 4) : (dy += 1) {
                var dx: u3 = 0;
                while (dx < 2) : (dx += 1) {
                    const px: i32 = @as(i32, col) * 2 + dx;
                    const py: i32 = @as(i32, row) * 4 + dy;
                    const manhattan = @mod(absInt(px - cx) + absInt(py - cy), spacing);
                    if (manhattan < threshold) {
                        dots |= brailleDotBit(dx, dy);
                    }
                }
            }
            const encoded = brailleEncode(dots);
            win.writeCell(col, row, .{
                .char = .{ .grapheme = &encoded, .width = 1 },
                .style = .{ .fg = color, .bg = global_bg },
            });
        }
    }
}

fn absInt(x: i32) i32 {
    return if (x < 0) -x else x;
}

fn renderWaveField(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    const amplitude: f32 = 6.0;
    const frequency: f32 = 0.15;
    const color: vaxis.Cell.Color = .{ .rgb = .{ 100, 160, 220 } };
    const cy = @as(f32, @floatFromInt(h)) * 2.0;

    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            var dots: u8 = 0;
            var dy: u3 = 0;
            while (dy < 4) : (dy += 1) {
                var dx: u3 = 0;
                while (dx < 2) : (dx += 1) {
                    const px = @as(f32, @floatFromInt(@as(i32, col) * 2 + dx));
                    const py = @as(f32, @floatFromInt(@as(i32, row) * 4 + dy));
                    const wave = cy + amplitude * @sin(px * frequency);
                    const dist = @abs(py - wave);
                    if (dist < 2.0) {
                        dots |= brailleDotBit(dx, dy);
                    }
                }
            }
            const encoded = brailleEncode(dots);
            win.writeCell(col, row, .{
                .char = .{ .grapheme = &encoded, .width = 1 },
                .style = .{ .fg = color, .bg = global_bg },
            });
        }
    }
}

// ── Character + Color Texture Renderers ─────────────────────────────────

fn renderWovenCrosshatch(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            const hue = @as(f32, @floatFromInt(col)) / @as(f32, @floatFromInt(if (w > 1) w - 1 else 1)) * 360.0;
            const rgb = hsvToRgb(hue, 0.6, 0.8);
            const glyph: []const u8 = if ((col + row) % 2 == 0)
                "\xe2\x95\xb1" // ╱
            else
                "\xe2\x95\xb2"; // ╲
            win.writeCell(col, row, .{
                .char = .{ .grapheme = glyph, .width = 1 },
                .style = .{ .fg = .{ .rgb = rgb }, .bg = global_bg },
            });
        }
    }
}

fn renderWovenCrosshatchGrey(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            const t = @as(f32, @floatFromInt(col)) / @as(f32, @floatFromInt(if (w > 1) w - 1 else 1));
            const v: u8 = @intFromFloat(lerp(60, 200, t));
            const glyph: []const u8 = if ((col + row) % 2 == 0)
                "\xe2\x95\xb1" // ╱
            else
                "\xe2\x95\xb2"; // ╲
            win.writeCell(col, row, .{
                .char = .{ .grapheme = glyph, .width = 1 },
                .style = .{ .fg = .{ .rgb = .{ v, v, v } }, .bg = global_bg },
            });
        }
    }
}

fn renderRadialGradientGrey(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    const cx = @as(f32, @floatFromInt(w)) / 2.0;
    const cy = @as(f32, @floatFromInt(h));
    const max_dist = @sqrt(cx * cx + cy * cy);

    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            const top_t = radialDist(col, row * 2, cx, cy, max_dist);
            const bot_t = radialDist(col, row * 2 + 1, cx, cy, max_dist);
            const top_v: u8 = @intFromFloat(lerp(16, 220, top_t));
            const bot_v: u8 = @intFromFloat(lerp(16, 220, bot_t));

            win.writeCell(col, row, .{
                .char = .{ .grapheme = "\xe2\x96\x80", .width = 1 },
                .style = .{
                    .fg = .{ .rgb = .{ top_v, top_v, top_v } },
                    .bg = .{ .rgb = .{ bot_v, bot_v, bot_v } },
                },
            });
        }
    }
}

fn renderHerringbone(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            // Herringbone: alternate direction every 2 columns, shift by row
            const block = (col + row) / 2;
            const glyph: []const u8 = if (block % 2 == 0)
                "\xe2\x95\xb1" // ╱
            else
                "\xe2\x95\xb2"; // ╲
            // Warm diagonal gradient
            const tx = @as(f32, @floatFromInt(col)) / @as(f32, @floatFromInt(if (w > 1) w - 1 else 1));
            const ty = @as(f32, @floatFromInt(row)) / @as(f32, @floatFromInt(if (h > 1) h - 1 else 1));
            const t = (tx + ty) / 2.0;
            const rgb: [3]u8 = .{
                @intFromFloat(lerp(180, 220, t)),
                @intFromFloat(lerp(80, 140, t)),
                @intFromFloat(lerp(40, 70, t)),
            };
            win.writeCell(col, row, .{
                .char = .{ .grapheme = glyph, .width = 1 },
                .style = .{ .fg = .{ .rgb = rgb }, .bg = global_bg },
            });
        }
    }
}

fn renderHerringboneGrey(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            const block = (col + row) / 2;
            const glyph: []const u8 = if (block % 2 == 0)
                "\xe2\x95\xb1" // ╱
            else
                "\xe2\x95\xb2"; // ╲
            const tx = @as(f32, @floatFromInt(col)) / @as(f32, @floatFromInt(if (w > 1) w - 1 else 1));
            const ty = @as(f32, @floatFromInt(row)) / @as(f32, @floatFromInt(if (h > 1) h - 1 else 1));
            const t = (tx + ty) / 2.0;
            const v: u8 = @intFromFloat(lerp(70, 210, t));
            win.writeCell(col, row, .{
                .char = .{ .grapheme = glyph, .width = 1 },
                .style = .{ .fg = .{ .rgb = .{ v, v, v } }, .bg = global_bg },
            });
        }
    }
}

fn renderBasketWeave(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    // Alternating 3-wide horizontal and vertical "strands"
    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            const bx = col / 3;
            const by = row / 2;
            const horizontal = (bx + by) % 2 == 0;
            const glyph: []const u8 = if (horizontal)
                "\xe2\x94\x80" // ─
            else
                "\xe2\x94\x82"; // │
            const t = @as(f32, @floatFromInt(col + row)) / @as(f32, @floatFromInt(w + h));
            const rgb: [3]u8 = .{
                @intFromFloat(lerp(160, 200, t)),
                @intFromFloat(lerp(120, 160, t)),
                @intFromFloat(lerp(80, 110, t)),
            };
            win.writeCell(col, row, .{
                .char = .{ .grapheme = glyph, .width = 1 },
                .style = .{ .fg = .{ .rgb = rgb }, .bg = global_bg },
            });
        }
    }
}

fn renderBasketWeaveGrey(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            const bx = col / 3;
            const by = row / 2;
            const horizontal = (bx + by) % 2 == 0;
            const glyph: []const u8 = if (horizontal)
                "\xe2\x94\x80" // ─
            else
                "\xe2\x94\x82"; // │
            const t = @as(f32, @floatFromInt(col + row)) / @as(f32, @floatFromInt(w + h));
            const v: u8 = @intFromFloat(lerp(90, 190, t));
            win.writeCell(col, row, .{
                .char = .{ .grapheme = glyph, .width = 1 },
                .style = .{ .fg = .{ .rgb = .{ v, v, v } }, .bg = global_bg },
            });
        }
    }
}

fn renderZigzag(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    // Continuous zigzag stripes — each row picks ╱ or ╲ based on column phase
    const period: u16 = 4;
    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            const phase = (col + row) % (period * 2);
            const glyph: []const u8 = if (phase < period)
                "\xe2\x95\xb1" // ╱
            else
                "\xe2\x95\xb2"; // ╲
            const t = @as(f32, @floatFromInt(row)) / @as(f32, @floatFromInt(if (h > 1) h - 1 else 1));
            const v: u8 = @intFromFloat(lerp(180, 80, t));
            const rgb: [3]u8 = .{ v, v, v };
            win.writeCell(col, row, .{
                .char = .{ .grapheme = glyph, .width = 1 },
                .style = .{ .fg = .{ .rgb = rgb }, .bg = global_bg },
            });
        }
    }
}

// Chevron: ╱╲ mirrored at center column, creating V-shapes
fn renderChevron(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    const mid = w / 2;
    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            const left = col < mid;
            const band = (if (left) col + row else (w - 1 - col) + row) / 3;
            const glyph: []const u8 = if (left)
                "\xe2\x95\xb2" // ╲
            else
                "\xe2\x95\xb1"; // ╱
            const t = @as(f32, @floatFromInt(band % 6)) / 5.0;
            const v: u8 = @intFromFloat(lerp(80, 200, t));
            win.writeCell(col, row, .{
                .char = .{ .grapheme = glyph, .width = 1 },
                .style = .{ .fg = .{ .rgb = .{ v, v, v } }, .bg = global_bg },
            });
        }
    }
}

// Diamond: ╱╲ arranged to form diamond/rhombus tiles
fn renderDiamond(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    const tile: u16 = 6;
    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            const tx = col % tile;
            const ty = row % tile;
            const half = tile / 2;
            const upper = ty < half;
            const glyph: []const u8 = if ((upper and tx < half) or (!upper and tx >= half))
                "\xe2\x95\xb1" // ╱
            else
                "\xe2\x95\xb2"; // ╲
            // Radial brightness from tile center
            const dx = @as(f32, @floatFromInt(tx)) - @as(f32, @floatFromInt(half));
            const dy = @as(f32, @floatFromInt(ty)) - @as(f32, @floatFromInt(half));
            const d = @sqrt(dx * dx + dy * dy) / @as(f32, @floatFromInt(half));
            const v: u8 = @intFromFloat(lerp(190, 90, @min(d, 1.0)));
            win.writeCell(col, row, .{
                .char = .{ .grapheme = glyph, .width = 1 },
                .style = .{ .fg = .{ .rgb = .{ v, v, v } }, .bg = global_bg },
            });
        }
    }
}

// Parquet: rotating blocks of parallel diagonals
fn renderParquet(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    const block: u16 = 4;
    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            const bx = col / block;
            const by = row / block;
            const glyph: []const u8 = if ((bx + by) % 2 == 0)
                "\xe2\x95\xb1" // ╱
            else
                "\xe2\x95\xb2"; // ╲
            const t = @as(f32, @floatFromInt(col)) / @as(f32, @floatFromInt(if (w > 1) w - 1 else 1));
            const v: u8 = @intFromFloat(lerp(100, 190, t));
            win.writeCell(col, row, .{
                .char = .{ .grapheme = glyph, .width = 1 },
                .style = .{ .fg = .{ .rgb = .{ v, v, v } }, .bg = global_bg },
            });
        }
    }
}

// Ripple: glyph chosen by distance from center (concentric diagonal rings)
fn renderRipple(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    const cx = @as(f32, @floatFromInt(w)) / 2.0;
    const cy = @as(f32, @floatFromInt(h)) / 2.0;
    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            const dx = @as(f32, @floatFromInt(col)) - cx;
            const dy = @as(f32, @floatFromInt(row)) - cy;
            const dist = @sqrt(dx * dx + dy * dy);
            const ring: u32 = @intFromFloat(dist);
            const glyph: []const u8 = if (ring % 4 < 2)
                "\xe2\x95\xb1" // ╱
            else
                "\xe2\x95\xb2"; // ╲
            const max_dist = @sqrt(cx * cx + cy * cy);
            const t = @min(dist / max_dist, 1.0);
            const v: u8 = @intFromFloat(lerp(200, 60, t));
            win.writeCell(col, row, .{
                .char = .{ .grapheme = glyph, .width = 1 },
                .style = .{ .fg = .{ .rgb = .{ v, v, v } }, .bg = global_bg },
            });
        }
    }
}

// Pinstripe: narrow alternating columns of ╱ and ╲, every 1 col
fn renderPinstripe(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            const glyph: []const u8 = if (col % 2 == 0)
                "\xe2\x95\xb1" // ╱
            else
                "\xe2\x95\xb2"; // ╲
            // Vertical fade: bright top, dim bottom
            const t = @as(f32, @floatFromInt(row)) / @as(f32, @floatFromInt(if (h > 1) h - 1 else 1));
            const v: u8 = @intFromFloat(lerp(200, 70, t));
            win.writeCell(col, row, .{
                .char = .{ .grapheme = glyph, .width = 1 },
                .style = .{ .fg = .{ .rgb = .{ v, v, v } }, .bg = global_bg },
            });
        }
    }
}

// Tumble: random-looking rotation per cell, seeded by position hash
fn renderTumble(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            const hv = hash2d(@intCast(col), @intCast(row));
            const glyph: []const u8 = if (hv % 2 == 0)
                "\xe2\x95\xb1" // ╱
            else
                "\xe2\x95\xb2"; // ╲
            // Brightness from hash too, but constrained range
            const v: u8 = 100 + (hv % 80);
            win.writeCell(col, row, .{
                .char = .{ .grapheme = glyph, .width = 1 },
                .style = .{ .fg = .{ .rgb = .{ v, v, v } }, .bg = global_bg },
            });
        }
    }
}

// Shingle: offset rows of same-direction runs, like roof shingles
fn renderShingle(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    const run_len: u16 = 5;
    var row: u16 = 0;
    while (row < h) : (row += 1) {
        const offset = (row / 2) * 3; // stagger each pair of rows
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            const pos = (col + offset) % (run_len * 2);
            const glyph: []const u8 = if (pos < run_len)
                "\xe2\x95\xb1" // ╱
            else
                "\xe2\x95\xb2"; // ╲
            const t = @as(f32, @floatFromInt(row)) / @as(f32, @floatFromInt(if (h > 1) h - 1 else 1));
            const v: u8 = @intFromFloat(lerp(180, 90, t));
            win.writeCell(col, row, .{
                .char = .{ .grapheme = glyph, .width = 1 },
                .style = .{ .fg = .{ .rgb = .{ v, v, v } }, .bg = global_bg },
            });
        }
    }
}

// Noise Weave: direction from smoothed noise, creates organic flowing grain
fn renderNoiseWeave(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    const scale: f32 = 0.25;
    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            const n = valueNoise2d(@as(f32, @floatFromInt(col)) * scale, @as(f32, @floatFromInt(row)) * scale);
            const glyph: []const u8 = if (n < 0.5)
                "\xe2\x95\xb1" // ╱
            else
                "\xe2\x95\xb2"; // ╲
            const v: u8 = @intFromFloat(lerp(80, 200, n));
            win.writeCell(col, row, .{
                .char = .{ .grapheme = glyph, .width = 1 },
                .style = .{ .fg = .{ .rgb = .{ v, v, v } }, .bg = global_bg },
            });
        }
    }
}

// ── Arc glyphs: ╭╮╰╯ ──────────────────────────────────────────────────

// Bubble: 2x2 tiles of ╭╮╰╯ creating closed cells
fn renderBubble(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    const arcs = [2][2][]const u8{
        .{ "\xe2\x95\xad", "\xe2\x95\xae" }, // ╭ ╮
        .{ "\xe2\x95\xb0", "\xe2\x95\xaf" }, // ╰ ╯
    };
    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            const glyph = arcs[row % 2][col % 2];
            const t = @as(f32, @floatFromInt(col + row)) / @as(f32, @floatFromInt(w + h));
            const v: u8 = @intFromFloat(lerp(100, 200, t));
            win.writeCell(col, row, .{
                .char = .{ .grapheme = glyph, .width = 1 },
                .style = .{ .fg = .{ .rgb = .{ v, v, v } }, .bg = global_bg },
            });
        }
    }
}

// Arc Ripple: arc chosen by distance from center, concentric rings
fn renderArcRipple(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    const cx = @as(f32, @floatFromInt(w)) / 2.0;
    const cy = @as(f32, @floatFromInt(h)) / 2.0;
    const max_dist = @sqrt(cx * cx + cy * cy);
    const arc_set = [4][]const u8{
        "\xe2\x95\xad", // ╭
        "\xe2\x95\xae", // ╮
        "\xe2\x95\xaf", // ╯
        "\xe2\x95\xb0", // ╰
    };
    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            const dx = @as(f32, @floatFromInt(col)) - cx;
            const dy = @as(f32, @floatFromInt(row)) - cy;
            const dist = @sqrt(dx * dx + dy * dy);
            const ring: u32 = @intFromFloat(dist);
            const quadrant: usize = (@as(usize, @intFromBool(dx >= 0)) << 1) | @as(usize, @intFromBool(dy >= 0));
            const idx = (ring + quadrant) % 4;
            const t = @min(dist / max_dist, 1.0);
            const v: u8 = @intFromFloat(lerp(200, 70, t));
            win.writeCell(col, row, .{
                .char = .{ .grapheme = arc_set[idx], .width = 1 },
                .style = .{ .fg = .{ .rgb = .{ v, v, v } }, .bg = global_bg },
            });
        }
    }
}

// ── Quadrant blocks: ▖▗▘▝ ─────────────────────────────────────────────

// Pixel Chevron: quadrant blocks mirrored at center
fn renderPixelChevron(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    const quads = [4][]const u8{
        "\xe2\x96\x98", // ▘
        "\xe2\x96\x9d", // ▝
        "\xe2\x96\x96", // ▖
        "\xe2\x96\x97", // ▗
    };
    const mid = w / 2;
    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            const dist_from_center = if (col < mid) mid - col else col - mid;
            const band = (dist_from_center + row) % 4;
            const t = @as(f32, @floatFromInt(row)) / @as(f32, @floatFromInt(if (h > 1) h - 1 else 1));
            const v: u8 = @intFromFloat(lerp(180, 80, t));
            win.writeCell(col, row, .{
                .char = .{ .grapheme = quads[band], .width = 1 },
                .style = .{ .fg = .{ .rgb = .{ v, v, v } }, .bg = global_bg },
            });
        }
    }
}

// Pixel Tumble: hash-randomized quadrant blocks
fn renderPixelTumble(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    const quads = [4][]const u8{
        "\xe2\x96\x98", // ▘
        "\xe2\x96\x9d", // ▝
        "\xe2\x96\x96", // ▖
        "\xe2\x96\x97", // ▗
    };
    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            const hv = hash2d(@intCast(col), @intCast(row));
            const idx: usize = @intCast(hv % 4);
            const v: u8 = 100 + (hv % 80);
            win.writeCell(col, row, .{
                .char = .{ .grapheme = quads[idx], .width = 1 },
                .style = .{ .fg = .{ .rgb = .{ v, v, v } }, .bg = global_bg },
            });
        }
    }
}

// ── Triangles: ◢◣◤◥ ───────────────────────────────────────────────────

// Triangle Parquet: rotating blocks of filled triangles
fn renderTriangleParquet(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    const tris = [4][]const u8{
        "\xe2\x97\xa2", // ◢
        "\xe2\x97\xa3", // ◣
        "\xe2\x97\xa4", // ◤
        "\xe2\x97\xa5", // ◥
    };
    const block: u16 = 4;
    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            const bx = col / block;
            const by = row / block;
            const idx: usize = (bx + by * 2) % 4;
            const t = @as(f32, @floatFromInt(col)) / @as(f32, @floatFromInt(if (w > 1) w - 1 else 1));
            const v: u8 = @intFromFloat(lerp(90, 200, t));
            win.writeCell(col, row, .{
                .char = .{ .grapheme = tris[idx], .width = 1 },
                .style = .{ .fg = .{ .rgb = .{ v, v, v } }, .bg = global_bg },
            });
        }
    }
}

// Triangle Noise: smooth noise picks triangle orientation
fn renderTriangleNoise(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    const tris = [4][]const u8{
        "\xe2\x97\xa2", // ◢
        "\xe2\x97\xa3", // ◣
        "\xe2\x97\xa4", // ◤
        "\xe2\x97\xa5", // ◥
    };
    const scale: f32 = 0.2;
    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            const n = valueNoise2d(@as(f32, @floatFromInt(col)) * scale, @as(f32, @floatFromInt(row)) * scale);
            const idx: usize = @min(@as(usize, @intFromFloat(n * 3.99)), 3);
            const v: u8 = @intFromFloat(lerp(80, 200, n));
            win.writeCell(col, row, .{
                .char = .{ .grapheme = tris[idx], .width = 1 },
                .style = .{ .fg = .{ .rgb = .{ v, v, v } }, .bg = global_bg },
            });
        }
    }
}

// ── Box lines: ─│ ──────────────────────────────────────────────────────

// Grid Weave: alternating ─│ in noise-modulated patches
fn renderGridWeave(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    const scale: f32 = 0.3;
    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            const n = valueNoise2d(@as(f32, @floatFromInt(col)) * scale, @as(f32, @floatFromInt(row)) * scale);
            const glyph: []const u8 = if (n < 0.5)
                "\xe2\x94\x80" // ─
            else
                "\xe2\x94\x82"; // │
            const v: u8 = @intFromFloat(lerp(90, 190, n));
            win.writeCell(col, row, .{
                .char = .{ .grapheme = glyph, .width = 1 },
                .style = .{ .fg = .{ .rgb = .{ v, v, v } }, .bg = global_bg },
            });
        }
    }
}

// Grid Shingle: staggered runs of ─ and │ like brickwork
fn renderGridShingle(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    const run_len: u16 = 6;
    var row: u16 = 0;
    while (row < h) : (row += 1) {
        const offset = (row / 2) * 3;
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            const pos = (col + offset) % (run_len * 2);
            const glyph: []const u8 = if (pos < run_len)
                "\xe2\x94\x80" // ─
            else
                "\xe2\x94\x82"; // │
            const t = @as(f32, @floatFromInt(col)) / @as(f32, @floatFromInt(if (w > 1) w - 1 else 1));
            const v: u8 = @intFromFloat(lerp(100, 190, t));
            win.writeCell(col, row, .{
                .char = .{ .grapheme = glyph, .width = 1 },
                .style = .{ .fg = .{ .rgb = .{ v, v, v } }, .bg = global_bg },
            });
        }
    }
}

// Grid Maze: hash picks ─│┌┐└┘ creating random maze-like corridors
fn renderGridMaze(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    const glyphs = [6][]const u8{
        "\xe2\x94\x80", // ─
        "\xe2\x94\x82", // │
        "\xe2\x94\x8c", // ┌
        "\xe2\x94\x90", // ┐
        "\xe2\x94\x94", // └
        "\xe2\x94\x98", // ┘
    };
    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            const hv = hash2d(@intCast(col), @intCast(row));
            const idx: usize = @intCast(hv % 6);
            const v: u8 = 100 + (hv % 80);
            win.writeCell(col, row, .{
                .char = .{ .grapheme = glyphs[idx], .width = 1 },
                .style = .{ .fg = .{ .rgb = .{ v, v, v } }, .bg = global_bg },
            });
        }
    }
}

// Grid Plaid: ─ on even rows, │ on even cols, ┼ where both meet
fn renderGridPlaid(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    const spacing: u16 = 3;
    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            const on_h = row % spacing == 0;
            const on_v = col % spacing == 0;
            const glyph: []const u8 = if (on_h and on_v)
                "\xe2\x94\xbc" // ┼
            else if (on_h)
                "\xe2\x94\x80" // ─
            else if (on_v)
                "\xe2\x94\x82" // │
            else
                " ";
            const bright: u8 = if (on_h and on_v) 200 else if (on_h or on_v) 140 else 50;
            win.writeCell(col, row, .{
                .char = .{ .grapheme = glyph, .width = 1 },
                .style = .{ .fg = .{ .rgb = .{ bright, bright, bright } }, .bg = global_bg },
            });
        }
    }
}

// Grid Ripple: ─│ chosen by distance from center
fn renderGridRipple(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    const cx = @as(f32, @floatFromInt(w)) / 2.0;
    const cy = @as(f32, @floatFromInt(h)) / 2.0;
    const max_dist = @sqrt(cx * cx + cy * cy);
    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            const dx = @as(f32, @floatFromInt(col)) - cx;
            const dy = @as(f32, @floatFromInt(row)) - cy;
            const dist = @sqrt(dx * dx + dy * dy);
            const ring: u32 = @intFromFloat(dist);
            const glyph: []const u8 = if (ring % 4 < 2)
                "\xe2\x94\x80" // ─
            else
                "\xe2\x94\x82"; // │
            const t = @min(dist / max_dist, 1.0);
            const v: u8 = @intFromFloat(lerp(200, 60, t));
            win.writeCell(col, row, .{
                .char = .{ .grapheme = glyph, .width = 1 },
                .style = .{ .fg = .{ .rgb = .{ v, v, v } }, .bg = global_bg },
            });
        }
    }
}

// Grid Chevron: ─│ mirrored at center creating V-bands
fn renderGridChevron(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    const mid = w / 2;
    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            const dist = if (col < mid) mid - col else col - mid;
            const band = (dist + row) / 3;
            const glyph: []const u8 = if (band % 2 == 0)
                "\xe2\x94\x80" // ─
            else
                "\xe2\x94\x82"; // │
            const t = @as(f32, @floatFromInt(band % 8)) / 7.0;
            const v: u8 = @intFromFloat(lerp(80, 200, t));
            win.writeCell(col, row, .{
                .char = .{ .grapheme = glyph, .width = 1 },
                .style = .{ .fg = .{ .rgb = .{ v, v, v } }, .bg = global_bg },
            });
        }
    }
}

// Grid Parquet: rotating blocks of ─ and │
fn renderGridParquet(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    const block: u16 = 5;
    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            const bx = col / block;
            const by = row / block;
            const glyph: []const u8 = if ((bx + by) % 2 == 0)
                "\xe2\x94\x80" // ─
            else
                "\xe2\x94\x82"; // │
            const t = @as(f32, @floatFromInt(col + row)) / @as(f32, @floatFromInt(w + h));
            const v: u8 = @intFromFloat(lerp(90, 190, t));
            win.writeCell(col, row, .{
                .char = .{ .grapheme = glyph, .width = 1 },
                .style = .{ .fg = .{ .rgb = .{ v, v, v } }, .bg = global_bg },
            });
        }
    }
}

// Grid Ladder: alternating rows of ─ with │ spacers
fn renderGridLadder(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    const rung_spacing: u16 = 3;
    const rail_spacing: u16 = 5;
    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            const on_rung = row % rung_spacing == 0;
            const on_rail = col % rail_spacing == 0;
            const glyph: []const u8 = if (on_rung)
                "\xe2\x94\x80" // ─
            else if (on_rail)
                "\xe2\x94\x82" // │
            else
                " ";
            const v: u8 = if (on_rung or on_rail) 160 else 40;
            const t = @as(f32, @floatFromInt(row)) / @as(f32, @floatFromInt(if (h > 1) h - 1 else 1));
            const fade: u8 = @intFromFloat(lerp(0.7, 1.0, t) * @as(f32, @floatFromInt(v)));
            win.writeCell(col, row, .{
                .char = .{ .grapheme = glyph, .width = 1 },
                .style = .{ .fg = .{ .rgb = .{ fade, fade, fade } }, .bg = global_bg },
            });
        }
    }
}

// Grid Cross: ┼ at intersections, ─│ between, creating a dense cross pattern
fn renderGridCross(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            const phase_x = col % 4;
            const phase_y = row % 4;
            const at_cross = phase_x == 0 and phase_y == 0;
            const on_h = phase_y == 0;
            const on_v = phase_x == 0;
            const glyph: []const u8 = if (at_cross)
                "\xe2\x94\xbc" // ┼
            else if (on_h)
                "\xe2\x94\x80" // ─
            else if (on_v)
                "\xe2\x94\x82" // │
            else
                "\xc2\xb7"; // ·
            const v: u8 = if (at_cross) 200 else if (on_h or on_v) 150 else 70;
            win.writeCell(col, row, .{
                .char = .{ .grapheme = glyph, .width = 1 },
                .style = .{ .fg = .{ .rgb = .{ v, v, v } }, .bg = global_bg },
            });
        }
    }
}

// Grid Static: all box-drawing pieces hash-selected for dense texture
fn renderGridStatic(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    const glyphs = [11][]const u8{
        "\xe2\x94\x80", // ─
        "\xe2\x94\x82", // │
        "\xe2\x94\x8c", // ┌
        "\xe2\x94\x90", // ┐
        "\xe2\x94\x94", // └
        "\xe2\x94\x98", // ┘
        "\xe2\x94\x9c", // ├
        "\xe2\x94\xa4", // ┤
        "\xe2\x94\xac", // ┬
        "\xe2\x94\xb4", // ┴
        "\xe2\x94\xbc", // ┼
    };
    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            const hv = hash2d(@intCast(col), @intCast(row));
            const idx: usize = @intCast(hv % 11);
            const v: u8 = 90 + (hv % 90);
            win.writeCell(col, row, .{
                .char = .{ .grapheme = glyphs[idx], .width = 1 },
                .style = .{ .fg = .{ .rgb = .{ v, v, v } }, .bg = global_bg },
            });
        }
    }
}

fn renderShadeGradient(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    const shades = [4][]const u8{
        "\xe2\x96\x91", // ░
        "\xe2\x96\x92", // ▒
        "\xe2\x96\x93", // ▓
        "\xe2\x96\x88", // █
    };
    const cx = @as(f32, @floatFromInt(w)) / 2.0;
    const cy = @as(f32, @floatFromInt(h)) / 2.0;
    const max_dist = @sqrt(cx * cx + cy * cy);

    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            const dx = @as(f32, @floatFromInt(col)) - cx;
            const dy = @as(f32, @floatFromInt(row)) - cy;
            const d = @sqrt(dx * dx + dy * dy) / max_dist;
            const t = @min(d, 1.0);
            const idx: usize = @min(@as(usize, @intFromFloat(t * 3.99)), 3);
            const v: u8 = @intFromFloat(lerp(200, 60, t));
            win.writeCell(col, row, .{
                .char = .{ .grapheme = shades[idx], .width = 1 },
                .style = .{
                    .fg = .{ .rgb = .{ v, @min(v + 10, 255), @min(v + 30, 255) } },
                    .bg = global_bg,
                },
            });
        }
    }
}

fn renderEmberNoise(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    const shades = [3][]const u8{
        "\xe2\x96\x91", // ░
        "\xe2\x96\x92", // ▒
        "\xe2\x96\x93", // ▓
    };
    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            const h_val = hash2d(@intCast(col), @intCast(row));
            const shade_idx: usize = @intCast(h_val % 3);
            const base: u8 = 100 + (h_val % 80);
            win.writeCell(col, row, .{
                .char = .{ .grapheme = shades[shade_idx], .width = 1 },
                .style = .{
                    .fg = .{ .rgb = .{ @min(@as(u16, base) + 60, 240), base, base / 3 } },
                    .bg = global_bg,
                },
            });
        }
    }
}

fn renderShadeNoise(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    const shades = [3][]const u8{
        "\xe2\x96\x91", // ░
        "\xe2\x96\x92", // ▒
        "\xe2\x96\x93", // ▓
    };
    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            const h_val = hash2d(@intCast(col), @intCast(row));
            const shade_idx: usize = @intCast(h_val % 3);
            const brightness: u8 = 120 + (h_val % 60);
            win.writeCell(col, row, .{
                .char = .{ .grapheme = shades[shade_idx], .width = 1 },
                .style = .{
                    .fg = .{ .rgb = .{ brightness, @min(brightness + 20, 255), @min(brightness + 60, 255) } },
                    .bg = global_bg,
                },
            });
        }
    }
}

fn renderChecker(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    const c1: vaxis.Cell.Color = .{ .rgb = .{ 60, 60, 90 } };
    const c2: vaxis.Cell.Color = .{ .rgb = .{ 40, 40, 60 } };

    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            const bg = if ((col + row) % 2 == 0) c1 else c2;
            win.writeCell(col, row, .{
                .style = .{ .bg = bg },
            });
        }
    }
}

fn renderStarField(win: vaxis.Window, ox: u16, oy: u16, w: u16, h: u16) void {
    _ = ox;
    _ = oy;
    const glyphs = [3][]const u8{
        "\xe2\x9c\xa6", // ✦
        "\xe2\x8b\x86", // ⋆
        "\xc2\xb7", // ·
    };

    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            const h_val = hash2d(@as(i32, @intCast(col)) +% 97, @as(i32, @intCast(row)) +% 131);
            if (h_val < 30) {
                // Star! Pick glyph and brightness
                const glyph_idx: usize = @intCast(h_val % 3);
                const brightness: u8 = 80 + @as(u8, @intCast(h_val)) * 5;
                win.writeCell(col, row, .{
                    .char = .{ .grapheme = glyphs[glyph_idx], .width = 1 },
                    .style = .{
                        .fg = .{ .rgb = .{ brightness, brightness, @min(@as(u16, brightness) + 20, 240) } },
                        .bg = global_bg,
                    },
                });
            } else {
                win.writeCell(col, row, .{
                    .style = .{ .bg = global_bg },
                });
            }
        }
    }
}

// ── Main ────────────────────────────────────────────────────────────────

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
    try vx.queryTerminal(tty.writer(), 1 * std.time.ns_per_s);

    var scroll_offset: i32 = 0;
    var alpha: f32 = 0.2;

    while (true) {
        defer tty.writer().flush() catch {};
        const event = loop.nextEvent();

        switch (event) {
            .key_press => |key| {
                if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) break;
                if (key.matches('l', .{ .ctrl = true })) vx.queueRefresh();
                if (key.matchesAny(&.{ vaxis.Key.down, 'j' }, .{})) scroll_offset += 3;
                if (key.matchesAny(&.{ vaxis.Key.up, 'k' }, .{})) scroll_offset -= 3;
                if (key.matches(vaxis.Key.page_down, .{})) scroll_offset += 10;
                if (key.matches(vaxis.Key.page_up, .{})) scroll_offset -= 10;
                if (key.matches(vaxis.Key.left, .{}) or key.matches('h', .{})) alpha = @max(0.1, alpha - 0.1);
                if (key.matches(vaxis.Key.right, .{}) or key.matches('l', .{})) alpha = @min(0.9, alpha + 0.1);
            },
            .winsize => |ws| try vx.resize(alloc, tty.writer(), ws),
        }

        const win = vx.window();
        win.clear();
        win.fill(.{ .style = .{ .bg = global_bg } });

        if (win.height < 4 or win.width < 20) {
            try vx.render(tty.writer());
            continue;
        }

        // ── Header ──
        _ = win.printSegment(.{
            .text = " Texture Gallery",
            .style = .{ .fg = header_fg, .bg = global_bg, .bold = true },
        }, .{ .row_offset = 0 });

        // Slider: "opacity ◁━━━━●━━━━▷ 0.5"
        const slider_w: u16 = 9;
        const step: u16 = @intFromFloat(@round((alpha - 0.1) / 0.1));
        const slider_label = " opacity \xe2\x97\x81"; // " opacity ◁"
        const slider_label_len: u16 = 11;
        var slider_buf: [slider_w]u8 = undefined;
        for (0..slider_w) |si| {
            slider_buf[si] = if (si == step) '\xa9' else '\x81';
        }
        // Draw slider track with writeCell for precise positioning
        const slider_start: u16 = slider_label_len;
        _ = win.printSegment(.{
            .text = slider_label,
            .style = .{ .fg = tag_fg, .bg = global_bg },
        }, .{ .col_offset = slider_start -| slider_label_len, .row_offset = 0 });
        for (0..slider_w) |si| {
            const glyph: []const u8 = if (si == step) "\xe2\x97\x8f" else "\xe2\x94\x80"; // ● or ─
            const fg = if (si == step) header_fg else tag_fg;
            win.writeCell(slider_start + @as(u16, @intCast(si)), 0, .{
                .char = .{ .grapheme = glyph, .width = 1 },
                .style = .{ .fg = fg, .bg = global_bg },
            });
        }
        const after_slider = slider_start + slider_w;
        _ = win.printSegment(.{
            .text = "\xe2\x97\xb7", // ▷
            .style = .{ .fg = tag_fg, .bg = global_bg },
        }, .{ .col_offset = after_slider, .row_offset = 0 });

        // Alpha value display
        const alpha_digit: u8 = '0' + @as(u8, @intFromFloat(@round(alpha * 10)));
        const alpha_str: [3]u8 = .{ '0', '.', alpha_digit };
        _ = win.printSegment(.{
            .text = " ",
            .style = .{ .fg = tag_fg, .bg = global_bg },
        }, .{ .col_offset = after_slider + 1, .row_offset = 0 });
        _ = win.printSegment(.{
            .text = &alpha_str,
            .style = .{ .fg = label_fg, .bg = global_bg },
        }, .{ .col_offset = after_slider + 2, .row_offset = 0 });

        const quit_hint = "q to quit ";
        const quit_col: u16 = if (win.width > @as(u16, @intCast(quit_hint.len)))
            win.width - @as(u16, @intCast(quit_hint.len))
        else
            0;
        _ = win.printSegment(.{
            .text = quit_hint,
            .style = .{ .fg = tag_fg, .bg = global_bg },
        }, .{ .col_offset = quit_col, .row_offset = 0 });

        // ── Layout ──
        const margin_x: u16 = 2;
        const margin_top: u16 = 2; // 1 header + 1 gap
        const card_gap: u16 = 1;
        const card_h: u16 = 9; // 1 label + 8 texture

        const usable_w = win.width -| (margin_x * 2);
        const cols: u16 = 1;
        const card_w: u16 = if (cols > 1) (usable_w -| (card_gap * (cols - 1))) / cols else usable_w;

        const total_rows: u16 = @intCast((textures.len + cols - 1) / cols);
        const total_content: i32 = @as(i32, margin_top) + @as(i32, total_rows) * (@as(i32, card_h) + card_gap);
        const max_scroll: i32 = @max(total_content - @as(i32, win.height), 0);
        scroll_offset = @max(0, @min(scroll_offset, max_scroll));

        for (0..textures.len) |i| {
            const grid_col: u16 = @intCast(i % cols);
            const grid_row: u16 = @intCast(i / cols);

            const cx: u16 = margin_x + grid_col * (card_w + card_gap);
            const cy_abs: i32 = @as(i32, margin_top) + @as(i32, grid_row) * (@as(i32, card_h) + card_gap) - scroll_offset;

            // Skip cards fully above or below viewport, or partially above
            if (cy_abs + @as(i32, card_h) <= 0) continue;
            if (cy_abs < 0) continue;
            if (cy_abs >= @as(i32, win.height)) continue;
            if (cx + card_w > win.width) continue;

            const cy: u16 = @intCast(cy_abs);

            const card = win.child(.{
                .x_off = @intCast(cx),
                .y_off = @intCast(cy),
                .width = card_w,
                .height = card_h,
            });

            // Draw border
            drawCardBorder(card, card_w, card_h);

            // Label row (inside border)
            const inner_x: u16 = 1;
            const inner_y: u16 = 1;
            const inner_w = card_w -| 2;
            const inner_h = card_h -| 2;

            // Write label: "Name (technique)"
            const tex = textures[i];
            _ = card.printSegment(.{
                .text = tex.name,
                .style = .{ .fg = label_fg, .bg = global_bg, .bold = true },
            }, .{ .col_offset = inner_x + 1, .row_offset = inner_y });

            const tag_text = techniqueTag(tex.technique);
            const name_len: u16 = @intCast(tex.name.len);
            _ = card.printSegment(.{
                .text = tag_text,
                .style = .{ .fg = tag_fg, .bg = global_bg },
            }, .{ .col_offset = inner_x + 1 + name_len + 1, .row_offset = inner_y });

            // Texture area: rows 2..card_h-1 inside border → inner_y+1..inner_y+inner_h
            const tex_h = inner_h -| 1;
            if (tex_h == 0 or inner_w == 0) continue;

            const tex_win = card.child(.{
                .x_off = @intCast(inner_x),
                .y_off = @intCast(inner_y + 1),
                .width = inner_w,
                .height = tex_h,
            });

            tex.render(tex_win, cx + inner_x, cy + inner_y + 1, inner_w, tex_h);

            // Post-process: blend toward global_bg by alpha
            applyAlpha(tex_win, inner_w, tex_h, alpha);
        }

        try vx.render(tty.writer());
    }
}

fn applyAlpha(win: vaxis.Window, w: u16, h: u16, alpha: f32) void {
    const bg_r: f32 = 16;
    const bg_g: f32 = 16;
    const bg_b: f32 = 24;
    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var col: u16 = 0;
        while (col < w) : (col += 1) {
            if (win.readCell(col, row)) |cell| {
                var new_cell = cell;
                new_cell.style.fg = blendColor(cell.style.fg, bg_r, bg_g, bg_b, alpha);
                new_cell.style.bg = blendColor(cell.style.bg, bg_r, bg_g, bg_b, alpha);
                win.writeCell(col, row, new_cell);
            }
        }
    }
}

fn blendColor(color: vaxis.Cell.Color, bg_r: f32, bg_g: f32, bg_b: f32, alpha: f32) vaxis.Cell.Color {
    switch (color) {
        .rgb => |rgb| {
            return .{ .rgb = .{
                @intFromFloat(lerp(bg_r, @as(f32, @floatFromInt(rgb[0])), alpha)),
                @intFromFloat(lerp(bg_g, @as(f32, @floatFromInt(rgb[1])), alpha)),
                @intFromFloat(lerp(bg_b, @as(f32, @floatFromInt(rgb[2])), alpha)),
            } };
        },
        else => return color,
    }
}

fn drawCardBorder(card: vaxis.Window, w: u16, h: u16) void {
    if (w < 2 or h < 2) return;

    const s: vaxis.Cell.Style = .{ .fg = card_border, .bg = global_bg };

    // Corners
    card.writeCell(0, 0, .{ .char = .{ .grapheme = "\xe2\x94\x8c" }, .style = s }); // ┌
    card.writeCell(w - 1, 0, .{ .char = .{ .grapheme = "\xe2\x94\x90" }, .style = s }); // ┐
    card.writeCell(0, h - 1, .{ .char = .{ .grapheme = "\xe2\x94\x94" }, .style = s }); // └
    card.writeCell(w - 1, h - 1, .{ .char = .{ .grapheme = "\xe2\x94\x98" }, .style = s }); // ┘

    // Horizontal edges
    var col: u16 = 1;
    while (col < w - 1) : (col += 1) {
        card.writeCell(col, 0, .{ .char = .{ .grapheme = "\xe2\x94\x80" }, .style = s }); // ─
        card.writeCell(col, h - 1, .{ .char = .{ .grapheme = "\xe2\x94\x80" }, .style = s }); // ─
    }

    // Vertical edges
    var row: u16 = 1;
    while (row < h - 1) : (row += 1) {
        card.writeCell(0, row, .{ .char = .{ .grapheme = "\xe2\x94\x82" }, .style = s }); // │
        card.writeCell(w - 1, row, .{ .char = .{ .grapheme = "\xe2\x94\x82" }, .style = s }); // │
    }
}
