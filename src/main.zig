const std = @import("std");

const hidder = @import("hidder");

pub fn main() !void {

    var gpa = std.heap.GeneralPurposeAllocator(.{}) {};
    const allocator = gpa.allocator();

    const devices_list = try hidder.discoverDevices(allocator);

    if (hidder.getXPPenDevice(devices_list) catch null) |xppen| {
        const descriptors = try hidder.getDescriptors(allocator, &xppen);
        for (descriptors) |desc| {
            if (!desc.isInput()) continue;
            const input = hidder.InputItem.fromHidItem(&desc);
            if (input.constant) continue;
            std.debug.print("{any}\n\n", .{input});
        }

        try hidder.readInputReports(&xppen);
    }
}
