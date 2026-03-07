const std = @import("std");

const hidder = @import("hidder");

pub fn main() !void {

    var gpa = std.heap.GeneralPurposeAllocator(.{}) {};
    const allocator = gpa.allocator();

    const devices_list = try hidder.discoverDevices(allocator);

    if (hidder.getXPPenDevice(devices_list) catch null) |xppen| {
        const descriptors = try hidder.getDescriptors(allocator, &xppen);
        for (descriptors.items) |item| {
            std.debug.print("{any}\n", .{item});
            if (!item.isInput()) continue;
            const input = hidder.InputItem.fromHidItem(&item);
            if (input.constant) continue;
        }

        try hidder.readReports(&xppen, descriptors.field_descriptors);
    }
}
