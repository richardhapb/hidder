/// Based in spec https://www.usb.org/sites/default/files/hid1_11.pdf
const std = @import("std");
const c = @import("c");

const XP_PEN_VENDOR_ID: u16 = 0x28bd;
const XP_PEN_PRODUCT_ID: u16 = 0x0913;
const STYLUS_INTERFACE: u8 = 1;

pub const DeviceInfo = struct { vendor_id: u16, product_id: u16, path: [:0]const u8, manufacturer: ?[:0]const u8, product: ?[:0]const u8, interface: i32 };

fn isNullCPtr(ptr: anytype) bool {
    return @intFromPtr(ptr) == 0;
}

fn wcharLen(ptr: [*c]const c.wchar_t) usize {
    var len: usize = 0;
    while (ptr[len] != 0) : (len += 1) {}
    return len;
}

fn wcharToUtf8AllocZ(allocator: std.mem.Allocator, wide: [*c]const c.wchar_t) !?[:0]u8 {
    if (isNullCPtr(wide)) return null;

    const ptr = wide;
    const len = wcharLen(ptr);

    return switch (@sizeOf(c.wchar_t)) {
        2 => {
            const wide16 = @as([*]const u16, @ptrCast(ptr))[0..len];
            return try std.unicode.utf16LeToUtf8AllocZ(allocator, wide16);
        },
        4 => {
            var utf8 = try std.ArrayList(u8).initCapacity(allocator, len * 4 + 1);
            errdefer utf8.deinit(allocator);

            const wide32 = @as([*]const c.wchar_t, @ptrCast(ptr))[0..len];
            for (wide32) |code_unit| {
                const raw: u32 = @bitCast(code_unit);
                const codepoint: u21 = if (raw <= 0x10FFFF) blk: {
                    const cp: u21 = @intCast(raw);
                    break :blk if (std.unicode.utf8ValidCodepoint(cp)) cp else std.unicode.replacement_character;
                } else std.unicode.replacement_character;

                var buf: [4]u8 = undefined;
                const n = try std.unicode.utf8Encode(codepoint, &buf);
                try utf8.appendSlice(allocator, buf[0..n]);
            }

            return try utf8.toOwnedSliceSentinel(allocator, 0);
        },
        else => return error.UnsupportedWcharWidth,
    };
}

pub fn initHidApi() !void {
    if (c.hid_init() == 0) return;
    return error.HidApiInitFailed;
}

pub fn discoverDevices(allocator: std.mem.Allocator) ![]DeviceInfo {
    const devices = c.hid_enumerate(0, 0) orelse return error.HidEnumerateFailed;
    defer c.hid_free_enumeration(devices);

    var list = try std.ArrayList(DeviceInfo).initCapacity(allocator, 100);
    errdefer list.deinit(allocator);

    var device: ?*c.struct_hid_device_info = devices;
    while (device) |dev| : (device = dev.next) {
        if (isNullCPtr(dev.path)) return error.HidDevicePathMissing;

        try list.append(allocator, .{
            .vendor_id = dev.vendor_id,
            .product_id = dev.product_id,
            .path = try allocator.dupeSentinel(u8, std.mem.span(dev.path), 0),
            .manufacturer = try wcharToUtf8AllocZ(allocator, dev.manufacturer_string),
            .product = try wcharToUtf8AllocZ(allocator, dev.product_string),
            .interface = dev.interface_number,
        });
    }

    std.log.info("found {} HID device{s}", .{
        list.items.len,
        if (list.items.len == 1) "" else "s",
    });

    return try list.toOwnedSlice(allocator);
}

pub fn getXPPenDevice(devices: []DeviceInfo) !?DeviceInfo {
    for (devices) |device| {
        if (device.vendor_id == XP_PEN_VENDOR_ID and
            device.product_id == XP_PEN_PRODUCT_ID and
            device.interface == STYLUS_INTERFACE)
        {
            return device;
        }
    }
    return null;
}

const HidItemType = enum(u2) {
    main = 0,
    global = 1,
    local = 2,
    reserved = 3,
};

const LocalState = struct {
    usages: [256]u32 = undefined,
    usage_count: u16 = 0,
    usage_min: ?u32 = null,
    usage_max: ?u32 = null,
    designator_index: ?u16 = null,
    designator_min: ?u16 = null,
    designator_max: ?u16 = null,
    string_index: ?u16 = null,
    string_min: ?u16 = null,
    string_max: ?u16 = null,

    fn appendUsage(self: *LocalState, usage: u32) void {
        if (self.usage_count < 256) {
            self.usages[self.usage_count] = usage;
            self.usage_count += 1;
        }
    }

    fn reset(self: *LocalState) void {
        self.usage_count = 0;
        self.usage_min = null;
        self.usage_max = null;
        self.designator_index = null;
        self.designator_min = null;
        self.designator_max = null;
        self.string_index = null;
        self.string_min = null;
        self.string_max = null;
    }
};

const GlobalState = struct {
    usage_page: u16 = 0,
    logical_min: i32 = 0,
    logical_max: i32 = 0,
    physical_min: i32 = 0,
    physical_max: i32 = 0,
    unit_exponent: i8 = 0,
    unit: u32 = 0,
    report_size: u16 = 0,
    report_count: u16 = 0,
    report_id: ?u8 = null,
};

const DescriptorState = struct {
    global: GlobalState = .{},
    local: LocalState = .{},
    global_stack: [16]GlobalState = undefined,
    stack_depth: u8 = 0,
    bit_offsets: std.AutoHashMap(u8, u16), // per report_id

    fn init(allocator: std.mem.Allocator) DescriptorState {
        return .{ .bit_offsets = std.AutoHashMap(u8, u16).init(allocator) };
    }

    fn deinit(self: *DescriptorState) void {
        self.bit_offsets.deinit();
    }

    fn getBitOffset(self: *DescriptorState) u16 {
        const id = self.global.report_id orelse 0;
        return self.bit_offsets.get(id) orelse if (self.global.report_id != null) 8 else 0;
    }

    fn addBitOffset(self: *DescriptorState, bits: u16) !void {
        const id = self.global.report_id orelse 0;
        const current = self.getBitOffset();
        try self.bit_offsets.put(id, current + bits);
    }

    fn push(self: *DescriptorState) !void {
        if (self.stack_depth >= 16) return error.StackOverflow;
        self.global_stack[self.stack_depth] = self.global;
        self.stack_depth += 1;
    }

    fn pop(self: *DescriptorState) !void {
        if (self.stack_depth == 0) return error.StackUnderflow;
        self.stack_depth -= 1;
        self.global = self.global_stack[self.stack_depth];
    }
};

pub const FieldDescriptor = struct {
    usage_page: u16,
    usage: u16,
    logical_min: i32,
    logical_max: i32,
    physical_min: i32,
    physical_max: i32,
    unit_exponent: i8,
    unit: u32,
    report_id: ?u8,
    bit_offset: u16,
    bit_size: u16,
    flags: u32, // raw INPUT/OUTPUT/FEATURE flags

    pub fn isConstant(self: *const FieldDescriptor) bool {
        return (self.flags & (1 << 0)) != 0;
    }

    pub fn isVariable(self: *const FieldDescriptor) bool {
        return (self.flags & (1 << 1)) != 0;
    }

    pub fn isRelative(self: *const FieldDescriptor) bool {
        return (self.flags & (1 << 2)) != 0;
    }

    pub fn extractRaw(self: *const FieldDescriptor, buf: []const u8) u32 {
        var result: u32 = 0;
        var i: u16 = 0;
        while (i < self.bit_size) : (i += 1) {
            const bit_pos = self.bit_offset + i;
            const byte_idx = bit_pos / 8;
            if (byte_idx >= buf.len) break;
            const bit_idx: u3 = @truncate(bit_pos % 8);
            const bit = (buf[byte_idx] >> bit_idx) & 1;
            result |= @as(u32, bit) << @truncate(i);
        }
        return result;
    }

    pub fn extractSigned(self: *const FieldDescriptor, buf: []const u8) i32 {
        const raw = self.extractRaw(buf);
        // Sign extend if logical_min is negative
        if (self.logical_min < 0) {
            const sign_bit = @as(u32, 1) << @as(u5, @intCast(self.bit_size - 1));
            if ((raw & sign_bit) != 0) {
                // Sign extend
                const mask = @as(u32, 0xFFFFFFFF) << @as(u5, @intCast(self.bit_size));
                return @bitCast(raw | mask);
            }
        }
        return @intCast(raw);
    }
};

const HidItem = struct {
    tag: u4,
    typ: HidItemType,
    data: u32,
    size: u8, // data byte count (0,1,2,4)

    pub fn isInput(self: *const HidItem) bool {
        return self.tag == 0b1000;
    }
};

pub const InputItem = struct {
    constant: bool,
    array: bool,
    relative: bool,
    wrap: bool,
    linear: bool,
    preferred: bool,
    nullable: bool,
    volat: bool,
    buffered: bool,

    pub fn fromHidItem(hid: *const HidItem) InputItem {
        std.debug.assert(hid.isInput());
        const d = hid.data;

        return .{
            .constant = (d & (1 << 0)) != 0, // 0=Data,      1=Constant
            .array = (d & (1 << 1)) == 0, // 0=Array,     1=Variable
            .relative = (d & (1 << 2)) != 0, // 0=Absolute,  1=Relative
            .wrap = (d & (1 << 3)) != 0, // 0=No Wrap,   1=Wrap
            .linear = (d & (1 << 4)) == 0, // 0=Linear,    1=Non Linear
            .preferred = (d & (1 << 5)) == 0, // 0=Preferred, 1=No Preferred
            .nullable = (d & (1 << 6)) != 0, // 0=No Null,   1=Null
            .volat = (d & (1 << 7)) != 0, // 0=Non Vol,   1=Volatile
            .buffered = (d & (1 << 9)) != 0, // 0=Bit Field, 1=Buffered Bytes
        };
    }
};

pub fn parseNextItem(buf: []const u8, offset: *usize) !HidItem {
    if (offset.* >= buf.len) return error.EndOfDescriptor;

    const prefix = buf[offset.*];
    offset.* += 1;

    // Long item
    if (prefix == 0b11111110) {
        if (offset.* + 2 > buf.len) return error.Truncated;
        const data_size = buf[offset.*];
        offset.* += 1;
        const long_tag = buf[offset.*];
        offset.* += 1;
        if (offset.* + data_size > buf.len) return error.Truncated;
        offset.* += data_size; // skip long item data for now
        return HidItem{ .tag = @truncate(long_tag >> 4), .typ = .reserved, .data = 0, .size = data_size };
    }

    // Short item
    const raw_size: u2 = @truncate(prefix & 0b11);
    const data_size: u8 = switch (raw_size) {
        0 => 0,
        1 => 1,
        2 => 2,
        3 => 4, // size=3 means 4 bytes per spec
    };
    const typ: HidItemType = @enumFromInt((prefix >> 2) & 0b11);
    const tag: u4 = @truncate(prefix >> 4);

    if (offset.* + data_size > buf.len) return error.Truncated;

    var data: u32 = 0;
    for (0..data_size) |i| {
        data |= @as(u32, buf[offset.* + i]) << @intCast(i * 8);
    }
    offset.* += data_size;

    return HidItem{ .tag = tag, .typ = typ, .data = data, .size = data_size };
}

const ReportDescriptor = struct {
    items: []HidItem,
    field_descriptors: []FieldDescriptor,
};

fn signExtend(value: u32, size: u8) i32 {
    if (size == 0 or size >= 32) return @bitCast(value);
    const sign_bit = @as(u32, 1) << @as(u5, @intCast(size - 1));
    if ((value & sign_bit) != 0) {
        const mask = @as(u32, 0xFFFFFFFF) << @as(u5, @intCast(size));
        return @bitCast(value | mask);
    }
    return @bitCast(value);
}

pub fn getDescriptors(allocator: std.mem.Allocator, device: *const DeviceInfo) !ReportDescriptor {
    var buf: [c.HID_API_MAX_REPORT_DESCRIPTOR_SIZE]u8 = undefined;
    const handle = c.hid_open_path(device.path) orelse return error.HidOpenFailed;
    defer c.hid_close(handle);

    const n = c.hid_get_report_descriptor(handle, &buf, buf.len);
    if (n < 0) return error.ReportDescriptorError;

    const descriptors_raw = buf[0..@intCast(n)];
    var items = try std.ArrayList(HidItem).initCapacity(allocator, 1);
    var descriptors = try std.ArrayList(FieldDescriptor).initCapacity(allocator, 1);
    var offset: usize = 0;

    var state = DescriptorState.init(allocator);
    defer state.deinit();

    while (offset < descriptors_raw.len) {
        const item = try parseNextItem(descriptors_raw, &offset);

        switch (item.typ) {
            .global => switch (item.tag) {
                0b0000 => state.global.usage_page = @truncate(item.data),
                0b0001 => state.global.logical_min = signExtend(item.data, item.size * 8),
                0b0010 => state.global.logical_max = signExtend(item.data, item.size * 8),
                0b0011 => state.global.physical_min = signExtend(item.data, item.size * 8),
                0b0100 => state.global.physical_max = signExtend(item.data, item.size * 8),
                0b0101 => state.global.unit_exponent = @truncate(@as(i32, @bitCast(item.data))),
                0b0110 => state.global.unit = item.data,
                0b0111 => state.global.report_size = @truncate(item.data),
                0b1000 => state.global.report_id = @truncate(item.data),
                0b1001 => state.global.report_count = @truncate(item.data),
                0b1010 => try state.push(),
                0b1011 => try state.pop(),
                else => {},
            },
            .local => switch (item.tag) {
                0b0000 => { // Usage
                    const usage: u32 = if (item.size >= 4) item.data else (item.data | (@as(u32, state.global.usage_page) << 16));
                    state.local.appendUsage(usage);
                },
                0b0001 => { // Usage Minimum
                    state.local.usage_min = if (item.size >= 4) item.data else (item.data | (@as(u32, state.global.usage_page) << 16));
                },
                0b0010 => { // Usage Maximum
                    state.local.usage_max = if (item.size >= 4) item.data else (item.data | (@as(u32, state.global.usage_page) << 16));
                },
                0b0011 => state.local.designator_index = @truncate(item.data),
                0b0100 => state.local.designator_min = @truncate(item.data),
                0b0101 => state.local.designator_max = @truncate(item.data),
                0b0111 => state.local.string_index = @truncate(item.data),
                0b1000 => state.local.string_min = @truncate(item.data),
                0b1001 => state.local.string_max = @truncate(item.data),
                else => {},
            },
            .main => {
                // Input (0b1000), Output (0b1001), Feature (0b1011) all define data fields
                if (item.tag == 0b1000 or item.tag == 0b1001 or item.tag == 0b1011) {
                    const report_count = state.global.report_count;
                    const report_size = state.global.report_size;

                    // Build usage list from explicit usages or usage range
                    var usage_list: [256]u32 = undefined;
                    var usage_count: u16 = 0;

                    if (state.local.usage_count > 0) {
                        for (state.local.usages[0..state.local.usage_count]) |u| {
                            if (usage_count < 256) {
                                usage_list[usage_count] = u;
                                usage_count += 1;
                            }
                        }
                    } else if (state.local.usage_min != null and state.local.usage_max != null) {
                        var u = state.local.usage_min.?;
                        while (u <= state.local.usage_max.? and usage_count < 256) : (u += 1) {
                            usage_list[usage_count] = u;
                            usage_count += 1;
                        }
                    }

                    // Create a field descriptor for each field in report_count
                    var i: u16 = 0;
                    while (i < report_count) : (i += 1) {
                        // Use corresponding usage, or last usage, or 0
                        const usage: u32 = if (i < usage_count)
                            usage_list[i]
                        else if (usage_count > 0)
                            usage_list[usage_count - 1]
                        else
                            @as(u32, state.global.usage_page) << 16;

                        try descriptors.append(allocator, .{
                            .usage_page = @truncate(usage >> 16),
                            .usage = @truncate(usage),
                            .logical_min = state.global.logical_min,
                            .logical_max = state.global.logical_max,
                            .physical_min = state.global.physical_min,
                            .physical_max = state.global.physical_max,
                            .unit_exponent = state.global.unit_exponent,
                            .unit = state.global.unit,
                            .report_id = state.global.report_id,
                            .bit_offset = state.getBitOffset(),
                            .bit_size = report_size,
                            .flags = item.data,
                        });

                        try state.addBitOffset(report_size);
                    }
                }
                // Reset local state after any Main item
                state.local.reset();
            },
            .reserved => {},
        }

        try items.append(allocator, item);
    }

    return .{ .items = try items.toOwnedSlice(allocator), .field_descriptors = try descriptors.toOwnedSlice(allocator) };
}

pub const FieldEvent = struct {
    descriptor: *const FieldDescriptor,
    old_value: i32,
    new_value: i32,
};

pub fn EventQueue(comptime T: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        buf: std.Deque(T),
        mutex: std.atomic.Mutex = .unlocked,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator, .buf = .empty };
        }

        pub fn deinit(self: *Self) void {
            self.buf.deinit(self.allocator);
        }

        fn lock(self: *Self) void {
            while (!self.mutex.tryLock()) {}
        }

        pub fn push(self: *Self, event: T) !void {
            self.lock();
            defer self.mutex.unlock();
            try self.buf.pushBack(self.allocator, event);
        }

        pub fn pop(self: *Self) ?T {
            self.lock();
            defer self.mutex.unlock();
            return self.buf.popFront();
        }
    };
}

pub const ReportsWatcher = struct {
    device: *const DeviceInfo,
    report: ReportDescriptor,
    subs_map: std.AutoHashMap(*FieldDescriptor, i32),
    subscriptions: []*const FieldDescriptor,
    queue: *EventQueue(FieldEvent),
    thread: ?std.Thread = null,

    pub fn init(allocator: std.mem.Allocator, device: *const DeviceInfo, report: ReportDescriptor, subscriptions: []*const FieldDescriptor, queue: *EventQueue(FieldEvent)) ReportsWatcher {
        return .{ .device = device, .report = report, .subs_map = std.AutoHashMap(*FieldDescriptor, i32).init(allocator), .subscriptions = subscriptions, .queue = queue };
    }

    pub fn deinit(self: *ReportsWatcher) void {
        self.subs_map.deinit();
    }

    pub fn start(self: *ReportsWatcher) !void {
        self.thread = try std.Thread.spawn(.{}, readReports, .{self});
    }
    pub fn stop(self: *ReportsWatcher) void {
        // we'll need an atomic flag for clean shutdown - for now:
        if (self.thread) |t| t.join();
    }

    pub fn readReports(self: *ReportsWatcher) !void {
        var buf: [64]u8 = undefined;
        const descriptors = self.report.field_descriptors;

        const handle = c.hid_open_path(self.device.path) orelse return error.HidOpenFailed;
        defer _ = c.hid_close(handle);

        while (true) {
            const result = c.hid_read(handle, &buf, buf.len);
            if (result < 0) return error.HidReadFailed;
            const n: usize = @intCast(result);
            if (n == 0) continue;

            // First byte is report ID if device uses report IDs
            const report_id: ?u8 = if (descriptors.len > 0 and descriptors[0].report_id != null)
                buf[0]
            else
                null;

            for (descriptors, 0..) |desc, i| {
                // Skip descriptors for other report IDs
                if (desc.report_id != null and desc.report_id != report_id) continue;
                // Skip constant fields (padding)
                if (desc.isConstant()) continue;

                const value = desc.extractSigned(buf[0..n]);
                // std.debug.print("page=0x{X:0>2} usage=0x{X:0>2}: {d}\n", .{ desc.usage_page, desc.usage, value });

                const prev_value = self.subs_map.get(@constCast(&descriptors[i]));
                try self.subs_map.put(@constCast(&descriptors[i]), value);

                const old = prev_value orelse continue;
                if (old != value and self.isTracked(&descriptors[i])) self.notify(&descriptors[i], old, value);
            }
            // std.debug.print("---\n", .{});
        }
    }

    fn isTracked(self: *const ReportsWatcher, desc: *const FieldDescriptor) bool {
        for (self.subscriptions) |sub| {
            if (sub == desc) return true;
        }

        return false;
    }

    fn notify(self: *ReportsWatcher, desc: *const FieldDescriptor, old: i32, new: i32) void {
        self.queue.push(.{
            .descriptor = desc,
            .old_value = old,
            .new_value = new,
        }) catch {
            std.log.err("Cannot notify event: {any}", .{desc});
        };
    }
};
