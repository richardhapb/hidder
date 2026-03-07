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
            .constant  = (d & (1 << 0)) == 1, // 0=Data,      1=Constant
            .array     = (d & (1 << 1)) == 0, // 0=Array,     1=Variable
            .relative  = (d & (1 << 2)) != 0, // 0=Absolute,  1=Relative
            .wrap      = (d & (1 << 3)) != 0, // 0=No Wrap,   1=Wrap
            .linear    = (d & (1 << 4)) == 0, // 0=Linear,    1=Non Linear
            .preferred = (d & (1 << 5)) == 0, // 0=Preferred, 1=No Preferred
            .nullable  = (d & (1 << 6)) != 0, // 0=No Null,   1=Null
            .volat     = (d & (1 << 7)) != 0, // 0=Non Vol,   1=Volatile
            .buffered  = (d & (1 << 9)) != 0, // 0=Bit Field, 1=Buffered Bytes
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

pub fn getDescriptors(allocator: std.mem.Allocator, device: *const DeviceInfo) ![]HidItem {
    var buf: [c.HID_API_MAX_REPORT_DESCRIPTOR_SIZE]u8 = undefined;
    const handle = c.hid_open_path(device.path) orelse return error.HidOpenFailed;
    defer c.hid_close(handle);

    const n = c.hid_get_report_descriptor(handle, &buf, buf.len);
    if (n < 0) return error.ReportDescriptorError;

    const descriptors = buf[0..@intCast(n)];
    var items = try std.ArrayList(HidItem).initCapacity(allocator, 1);
    var offset: usize = 0;

    while (offset < descriptors.len) {
        const item = try parseNextItem(descriptors, &offset);
        try items.append(allocator, item);
    }

    return items.toOwnedSlice(allocator);
}

pub fn readInputReports(device: *const DeviceInfo) !void {
    var buf: [64]u8 = undefined;

    std.debug.print("opening path: {s}\n", .{device.path});
    const handle = c.hid_open_path(device.path) orelse return error.HidOpenFailed;
    defer _ = c.hid_close(handle);

    for (0..1000) |_| {
        const n: usize = @intCast(c.hid_read(handle, &buf, buf.len));

        if (n < 0) return error.HidReadFailed;

        std.debug.print("Read {} interrupts, {any}\n", .{ n, buf[0..@intCast(n)] });

        for (0..n) |i| {
            std.debug.print("Int: {any}\n", .{buf[i]});
        }
    }
}

