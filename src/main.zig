const std = @import("std");

const hidder = @import("hidder");

const Events = enum {
    tip,
    button1,
    button2,
    pressure,
};

const MAX_PRESSURE: u16 = 8191;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const devices_list = try hidder.discoverDevices(allocator);

    if (hidder.getXPPenDevice(devices_list) catch null) |xppen| {
        const report = try hidder.getDescriptors(allocator, &xppen);

        var subs = [_]*const hidder.FieldDescriptor{ &report.field_descriptors[0], &report.field_descriptors[1], &report.field_descriptors[2], &report.field_descriptors[10] };
        var queue = hidder.EventQueue(hidder.FieldEvent).init(allocator);
        defer queue.deinit();
        var watcher = hidder.ReportsWatcher.init(allocator, &xppen, report, &subs, &queue);
        defer watcher.deinit();

        try watcher.start();
        defer watcher.stop();

        var events_map = std.AutoHashMap(*const hidder.FieldDescriptor, Events).init(allocator);
        try events_map.put(&report.field_descriptors[0], .tip);
        try events_map.put(&report.field_descriptors[1], .button1);
        try events_map.put(&report.field_descriptors[2], .button2);
        try events_map.put(&report.field_descriptors[10], .pressure);

        while (true) {
            while (watcher.queue.pop()) |event| {
                if (event.new_value == 0) continue;
                const event_type = events_map.get(event.descriptor) orelse continue;
                switch (event_type) {
                    .tip => std.debug.print("TIP\n", .{}),
                    .button1 => std.debug.print("Button 1\n", .{}),
                    .button2 => std.debug.print("Button 2\n", .{}),
                    .pressure => std.debug.print("Pressure: {d:.2}\n", .{@as(f32, @floatFromInt(event.new_value)) / MAX_PRESSURE * 100}),
                }
            }
        }
    }
}
