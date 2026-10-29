//! Real-time HTMX chat served by Baz.
//!
//! Browsers receive messages over Server-Sent Events (`GET /events`) and send
//! them with a regular form POST (`POST /chat`). Baz has no WebSocket support,
//! and SSE covers the one-way fan-out a chat room needs.
//!
//! All storage is fixed at startup: a ring of the most recent messages and a
//! table of subscriber notifications. Event ids are message sequence numbers,
//! so a reconnecting browser resumes from `Last-Event-ID` without gaps while
//! the ring still holds the messages it missed.
const std = @import("std");
const assert = std.debug.assert;
const baz = @import("baz");

const port_default = 3010;
const message_count_max = 64;
const message_text_bytes_max = 280;
/// Escaping expands one byte to at most six (`&quot;`), plus the markup around it.
const message_html_bytes_max = 6 * message_text_bytes_max + 256;
const subscriber_count_max = 32;
/// Bounds one flush so a reconnecting subscriber cannot exceed the response limit.
const events_per_flush_max = 16;
const user_name_bytes_max = "user-".len + 10;
const form_bytes_max = 4096;
const stream_timeout_ms = 5 * std.time.ms_per_min;
const heartbeat_interval_ns = 15 * std.time.ns_per_s;
const cookie_name = "zig-htmx-user";

comptime {
    assert(message_count_max >= events_per_flush_max);
    assert(std.math.isPowerOfTwo(message_count_max));
    assert(message_html_bytes_max <= std.math.maxInt(u16));
}

const Message = struct {
    sequence: u64 = 0,
    html_len: u16 = 0,
    html: [message_html_bytes_max]u8 = undefined,
};

/// The most recent messages, indexed by sequence number modulo the capacity.
const MessageLog = struct {
    messages: [message_count_max]Message = @splat(.{}),
    /// The sequence number of the newest message. Zero means empty.
    sequence_last: u64 = 0,

    fn append(log: *MessageLog, html: []const u8) void {
        assert(html.len > 0);
        assert(html.len <= message_html_bytes_max);

        log.sequence_last += 1;
        const message = &log.messages[log.sequence_last % message_count_max];
        message.sequence = log.sequence_last;
        message.html_len = @intCast(html.len);
        @memcpy(message.html[0..html.len], html);
    }

    /// The oldest sequence number still held, or `sequence_last + 1` when empty.
    fn sequence_first(log: *const MessageLog) u64 {
        if (log.sequence_last < message_count_max) return 1;
        return log.sequence_last - message_count_max + 1;
    }

    fn get(log: *const MessageLog, sequence: u64) []const u8 {
        assert(sequence >= log.sequence_first());
        assert(sequence <= log.sequence_last);

        const message = &log.messages[sequence % message_count_max];
        assert(message.sequence == sequence);
        return message.html[0..message.html_len];
    }
};

const Subscriber = struct {
    /// Set under the guard; cleared by stream cleanup without it.
    active: std.atomic.Value(bool) = .init(false),
    notification: baz.continuation.Notification = undefined,
};

const Shared = struct {
    /// Guards `log` and `subscribers`. HTTP callbacks never block on it: they
    /// retry later (streams) or answer 503 (posts) while it is held.
    busy: std.atomic.Value(bool) = .init(false),
    log: MessageLog = .{},
    subscribers: [subscriber_count_max]Subscriber = @splat(.{}),
    user_count: std.atomic.Value(u32) = .init(0),

    fn try_lock(shared: *Shared) bool {
        return !shared.busy.swap(true, .acquire);
    }

    fn unlock(shared: *Shared) void {
        assert(shared.busy.load(.monotonic));
        shared.busy.store(false, .release);
    }

    /// Append under the guard, then wake subscribers after releasing it.
    fn publish_locked(shared: *Shared, html: []const u8) void {
        assert(shared.busy.load(.monotonic));
        shared.log.append(html);

        var notifications: [subscriber_count_max]baz.continuation.Notification = undefined;
        var notification_count: usize = 0;
        for (&shared.subscribers) |*subscriber| {
            if (!subscriber.active.load(.acquire)) continue;
            notifications[notification_count] = subscriber.notification;
            notification_count += 1;
        }
        shared.unlock();

        // Copied handles hold no request pointers. A stale copy signals nothing.
        for (notifications[0..notification_count]) |notification| _ = notification.signal();
    }
};

const Application = baz.App(Shared);
const Context = Application.Context;
const Step = baz.continuation.Step;

const StreamState = struct {
    cursor: u64 = 0,
    subscriber: ?u8 = null,
    user_name_len: u8 = 0,
    user_name: [user_name_bytes_max]u8 = undefined,

    pub fn deinit(state: *StreamState, ctx: *Context) void {
        const subscriber = state.subscriber orelse return;
        state.subscriber = null;

        // Release the slot without the guard: publishers only copy handles of
        // active slots, and signalling a stale copy is harmless.
        ctx.shared.subscribers[subscriber].active.store(false, .release);

        // The leave notice is best effort; cleanup must not wait for the guard.
        if (!ctx.shared.try_lock()) return;

        var buffer: [message_html_bytes_max]u8 = undefined;
        const html = render_notice(&buffer, state.user_name[0..state.user_name_len], "left") catch {
            ctx.shared.unlock();
            return;
        };
        ctx.shared.publish_locked(html);
    }
};

fn index(ctx: *Context) !void {
    // Keep an existing, well-formed name so reloading the page keeps the user.
    const user_name_existing = (ctx.request.cookie(cookie_name) catch null) orelse "";
    if (!user_name_valid(user_name_existing)) {
        const user_number = ctx.shared.user_count.fetchAdd(1, .monotonic);
        var buffer: [user_name_bytes_max]u8 = undefined;
        const user_name = try std.fmt.bufPrint(&buffer, "user-{d}", .{user_number});
        try ctx.response.setCookie(cookie_name, user_name, .{ .same_site = .strict });
    }
    try ctx.response.header("Cache-Control", "no-store");
    try ctx.response.borrowBody(200, "text/html; charset=utf-8", @embedFile("index.html"));
}

fn chat(ctx: *Context) !void {
    const user_name = (ctx.request.cookie(cookie_name) catch null) orelse "";
    if (!user_name_valid(user_name)) return ctx.response.text(401, "Load the chat page first");

    var body: [form_bytes_max]u8 = undefined;
    const limits: baz.params.Limits = .{
        .max_bytes = body.len,
        .max_pairs = 1,
        .max_name_bytes = "message".len,
        .max_value_bytes = form_bytes_max,
    };
    const fields = ctx.request.formUrlEncoded(limits) catch |err| switch (err) {
        error.BodyNotContiguous => try baz.form.parse(try ctx.request.body().copyTo(&body), limits),
        else => return ctx.response.text(400, @errorName(err)),
    };
    const field = fields.firstRaw("message") orelse return ctx.response.text(400, "message is required");

    var text_buffer: [form_bytes_max]u8 = undefined;
    const text_decoded = baz.params.formDecodeInto(field.value_raw, &text_buffer) catch {
        return ctx.response.text(400, "Invalid message encoding");
    };
    const text = std.mem.trim(u8, text_decoded, &std.ascii.whitespace);
    if (text.len == 0) return ctx.response.text(204, "");
    if (text.len > message_text_bytes_max) return ctx.response.text(413, "Message is too long");
    if (!std.unicode.utf8ValidateSlice(text)) return ctx.response.text(400, "Message is not UTF-8");

    var html_buffer: [message_html_bytes_max]u8 = undefined;
    const html = try render_message(&html_buffer, user_name, text);

    if (!ctx.shared.try_lock()) return ctx.response.text(503, "Chat is busy, try again");
    ctx.shared.publish_locked(html);
    try ctx.response.text(204, "");
}

fn events_start(ctx: *Context, state: *StreamState) !Step {
    const user_name = (ctx.request.cookie(cookie_name) catch null) orelse "";
    if (!user_name_valid(user_name)) return stream_error(ctx, 401, "Load the chat page first");
    const cursor = last_event_id(ctx.request) catch return stream_error(ctx, 400, "Invalid Last-Event-ID");

    @memcpy(state.user_name[0..user_name.len], user_name);
    state.user_name_len = @intCast(user_name.len);

    if (!ctx.shared.try_lock()) return stream_error(ctx, 503, "Chat is busy, try again");
    const subscriber = for (&ctx.shared.subscribers, 0..) |*subscriber, index_subscriber| {
        if (subscriber.active.load(.acquire)) continue;
        subscriber.notification = ctx.notification() catch |err| {
            ctx.shared.unlock();
            return err;
        };
        subscriber.active.store(true, .release);
        break @as(u8, @intCast(index_subscriber));
    } else {
        ctx.shared.unlock();
        return stream_error(ctx, 503, "All subscriber slots are in use");
    };
    state.subscriber = subscriber;

    // A fresh connection starts at the newest message. A reconnect resumes.
    state.cursor = if (cursor) |sequence|
        @min(sequence, ctx.shared.log.sequence_last)
    else
        ctx.shared.log.sequence_last;

    if (cursor == null) {
        var buffer: [message_html_bytes_max]u8 = undefined;
        const html = try render_notice(&buffer, user_name, "joined");
        ctx.shared.publish_locked(html);
    } else {
        ctx.shared.unlock();
    }

    try ctx.response.header("Cache-Control", "no-store");
    _ = try ctx.response.snapshot(200, baz.sse.content_type, .{});
    return emit(ctx, state, false);
}

fn events_resume(ctx: *Context, state: *StreamState, event: baz.continuation.Event) !Step {
    return emit(ctx, state, event == .timer);
}

fn emit(ctx: *Context, state: *StreamState, timed_out: bool) !Step {
    if (!ctx.shared.try_lock()) return .{ .wait = 10 * std.time.ns_per_ms };
    defer ctx.shared.unlock();

    const log = &ctx.shared.log;
    assert(state.cursor <= log.sequence_last);
    if (state.cursor == log.sequence_last) {
        if (!timed_out) return .{ .await_notification = heartbeat_interval_ns };
        var output = try ctx.response.resumeSnapshot();
        try baz.sse.heartbeat(output.writer());
        return .flush;
    }

    // Messages older than the ring are gone. Skip ahead instead of failing.
    const sequence_start = @max(state.cursor + 1, log.sequence_first());
    const sequence_end = @min(log.sequence_last, sequence_start + events_per_flush_max - 1);
    assert(sequence_start <= sequence_end);

    var output = try ctx.response.resumeSnapshot();
    var sequence = sequence_start;
    while (sequence <= sequence_end) : (sequence += 1) {
        var id_buffer: [20]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buffer, "{d}", .{sequence});
        try baz.sse.write(output.writer(), .{
            .event = "message",
            .id = id,
            .data = log.get(sequence),
        });
    }
    state.cursor = sequence_end;
    return .flush;
}

fn stream_error(ctx: *Context, status: u16, message: []const u8) !Step {
    try ctx.response.text(status, message);
    return .finish;
}

fn last_event_id(request: baz.Request) !?u64 {
    var headers = request.headers();
    var result: ?u64 = null;
    while (headers.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name_raw, "Last-Event-ID")) continue;
        if (result != null) return error.DuplicateId;
        result = try std.fmt.parseInt(u64, header.value_raw, 10);
    }
    return result;
}

fn user_name_valid(user_name: []const u8) bool {
    if (user_name.len <= "user-".len) return false;
    if (user_name.len > user_name_bytes_max) return false;
    if (!std.mem.startsWith(u8, user_name, "user-")) return false;
    for (user_name["user-".len..]) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

fn render_message(buffer: []u8, user_name: []const u8, text: []const u8) ![]const u8 {
    assert(user_name_valid(user_name));
    assert(text.len <= message_text_bytes_max);

    var writer: std.Io.Writer = .fixed(buffer);
    try writer.print("<div class=\"ml-0\"><span class=\"font-bold\">{s}:</span> <span>", .{user_name});
    try write_html_escaped(&writer, text);
    try writer.writeAll("</span></div>");
    return writer.buffered();
}

fn render_notice(buffer: []u8, user_name: []const u8, action: []const u8) ![]const u8 {
    assert(user_name_valid(user_name));

    var writer: std.Io.Writer = .fixed(buffer);
    try writer.print("<div class=\"ml-0 italic text-gray-400\">{s} {s} the chat.</div>", .{
        user_name,
        action,
    });
    return writer.buffered();
}

fn write_html_escaped(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| switch (byte) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '"' => try writer.writeAll("&quot;"),
        '\'' => try writer.writeAll("&#39;"),
        else => try writer.writeByte(byte),
    };
}

pub fn main(init: std.process.Init) !void {
    const shared = try init.gpa.create(Shared);
    defer init.gpa.destroy(shared);
    shared.* = .{};

    const app = try Application.init(.{
        .allocator = init.gpa,
        .io = init.io,
        .shared = shared,
        .server = .{
            .port = port_default,
            .connections = subscriber_count_max * 2,
            .shards = 1,
            .max_timeout_ms = stream_timeout_ms,
        },
        .response = .{ .body_bytes = events_per_flush_max * (message_html_bytes_max + 64) },
        .max_continuations = subscriber_count_max,
        .max_continuation_state_bytes = @sizeOf(StreamState),
    });
    defer app.deinit();

    try app.route("GET", "/", index);
    try app.route("POST", "/chat", chat);
    try app.routeContinuation("GET", "/events", StreamState, events_start, events_resume, .{
        .timeout_ms = stream_timeout_ms,
    });

    try app.start();
    std.log.info("Connect with browser to http://localhost:{d}.", .{app.port()});
    std.log.info("Terminate with CTRL+C", .{});
    try app.run();
}

test "message log keeps the newest messages in sequence order" {
    var log: MessageLog = .{};
    try std.testing.expectEqual(@as(u64, 1), log.sequence_first());

    var buffer: [8]u8 = undefined;
    for (0..message_count_max + 3) |index_message| {
        log.append(try std.fmt.bufPrint(&buffer, "{d}", .{index_message + 1}));
    }
    try std.testing.expectEqual(@as(u64, message_count_max + 3), log.sequence_last);
    try std.testing.expectEqual(@as(u64, 4), log.sequence_first());
    try std.testing.expectEqualStrings("4", log.get(4));
    try std.testing.expectEqualStrings("67", log.get(log.sequence_last));
}

test "rendered messages escape HTML" {
    var buffer: [message_html_bytes_max]u8 = undefined;
    const html = try render_message(&buffer, "user-7", "<script>alert(\"x\")</script> & 'y'");
    try std.testing.expectEqualStrings(
        "<div class=\"ml-0\"><span class=\"font-bold\">user-7:</span> <span>" ++
            "&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; &#39;y&#39;</span></div>",
        html,
    );
}

test "the longest message fits the rendered buffer" {
    var buffer: [message_html_bytes_max]u8 = undefined;
    const text: [message_text_bytes_max]u8 = @splat('"');
    const html = try render_message(&buffer, "user-4294967295", &text);
    try std.testing.expect(html.len <= message_html_bytes_max);
}

test "user names must be generated names" {
    try std.testing.expect(user_name_valid("user-0"));
    try std.testing.expect(user_name_valid("user-4294967295"));
    try std.testing.expect(!user_name_valid(""));
    try std.testing.expect(!user_name_valid("user-"));
    try std.testing.expect(!user_name_valid("user-1a"));
    try std.testing.expect(!user_name_valid("admin-1"));
    try std.testing.expect(!user_name_valid("user-<b>1</b>"));
}
