//! Vulkan device bound to a DRM node. Rendering writes GBM scanout images.

const std = @import("std");
const core = @import("core");
const drm_format = @import("drm/format.zig");
const drm_fb = @import("drm/fb.zig");

const vk = @cImport({
    @cInclude("vulkan/vulkan.h");
});

const gbm = @cImport({
    @cInclude("gbm.h");
});

const instance_ext_drm = "VK_EXT_physical_device_drm";
const device_ext_mem_fd = "VK_KHR_external_memory_fd";
const device_ext_dma_buf = "VK_EXT_external_memory_dma_buf";
const device_ext_modifier = "VK_EXT_image_drm_format_modifier";

pub const Slot = struct {
    width: u32 = 0,
    height: u32 = 0,
    format: u32 = 0,
    fb_id: u32 = 0,
    bo: ?*gbm.struct_gbm_bo = null,
    image: vk.VkImage = null,
    memory: vk.VkDeviceMemory = null,
};

pub const Device = struct {
    gpa: std.mem.Allocator,
    instance: vk.VkInstance,
    physical: vk.VkPhysicalDevice,
    device: vk.VkDevice,
    queue: vk.VkQueue,
    queue_family: u32,
    command_pool: vk.VkCommandPool,
    command_buffer: vk.VkCommandBuffer,
    fence: vk.VkFence,
    gbm_device: *gbm.struct_gbm_device,
    staging: vk.VkBuffer = null,
    staging_memory: vk.VkDeviceMemory = null,
    staging_size: vk.VkDeviceSize = 0,
    staging_map: []u8 = &.{},

    const Self = @This();

    /// Opens a Vulkan device for `render_fd` and a GBM device on `card_fd`.
    pub fn create(gpa: std.mem.Allocator, render_fd: i32, card_fd: i32) !*Self {
        if (render_fd < 0 or card_fd < 0) return error.InvalidDrmFd;
        const ids = try fdDevIds(render_fd);
        const instance = try createInstance();
        errdefer vk.vkDestroyInstance(instance, null);
        const physical = try pickPhysicalDevice(instance, ids);
        const family = try findGraphicsQueue(physical);
        const device = try createLogicalDevice(physical, family);
        errdefer vk.vkDestroyDevice(device, null);
        const pool = try createCommandPool(device, family);
        errdefer vk.vkDestroyCommandPool(device, pool, null);
        const command_buffer = try allocateCommandBuffer(device, pool);
        const fence = try createFence(device);
        errdefer vk.vkDestroyFence(device, fence, null);
        const gbm_device = gbm.gbm_create_device(card_fd) orelse return error.GbmDeviceCreationFailed;
        errdefer gbm.gbm_device_destroy(gbm_device);

        var queue: vk.VkQueue = null;
        vk.vkGetDeviceQueue(device, family, 0, &queue);
        const self = try gpa.create(Self);
        self.* = .{
            .gpa = gpa,
            .instance = instance,
            .physical = physical,
            .device = device,
            .queue = queue,
            .queue_family = family,
            .command_pool = pool,
            .command_buffer = command_buffer,
            .fence = fence,
            .gbm_device = gbm_device,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        _ = vk.vkDeviceWaitIdle(self.device);
        self.destroyStaging();
        vk.vkDestroyFence(self.device, self.fence, null);
        vk.vkDestroyCommandPool(self.device, self.command_pool, null);
        vk.vkDestroyDevice(self.device, null);
        vk.vkDestroyInstance(self.instance, null);
        gbm.gbm_device_destroy(self.gbm_device);
        self.gpa.destroy(self);
    }

    /// Control plane only: create or resize a GBM+Vulkan scanout slot.
    pub fn ensureSlot(
        self: *Self,
        slot: *Slot,
        drm_fd: i32,
        width: u32,
        height: u32,
        format: u32,
        modifiers: []const u64,
        allow_modifiers: bool,
    ) bool {
        if (vkFormat(format) == null) return false;
        if (slotReady(slot.*, width, height, format)) return true;
        self.destroySlot(slot, drm_fd);
        const bo = createBo(self.gbm_device, width, height, format, modifiers) orelse return false;
        slot.* = .{
            .width = width,
            .height = height,
            .format = format,
            .bo = bo,
        };
        slot.fb_id = addSlotFb(drm_fd, bo, width, height, format, allow_modifiers) orelse {
            self.destroySlot(slot, drm_fd);
            return false;
        };
        self.importSlotImage(slot, bo);
        if (!self.growStaging(stagingBytes(width, height))) {
            self.destroySlot(slot, drm_fd);
            return false;
        }
        _ = self.clearSlot(slot);
        return true;
    }

    pub fn destroySlot(self: *Self, slot: *Slot, drm_fd: i32) void {
        if (slot.fb_id != 0) {
            drmRmFb(drm_fd, slot.fb_id);
            slot.fb_id = 0;
        }
        if (slot.image != null) vk.vkDestroyImage(self.device, slot.image, null);
        if (slot.memory != null) vk.vkFreeMemory(self.device, slot.memory, null);
        if (slot.bo) |bo| gbm.gbm_bo_destroy(bo);
        slot.* = .{};
    }

    /// Upload tightly packed or strided pixels with a Vulkan copy when possible.
    pub fn upload(self: *Self, slot: *Slot, src: []const u8, src_stride: u32) bool {
        if (!scanoutStrideOk(src_stride, slot.width)) return false;
        if (slot.image != null) return self.uploadVulkan(slot, src, src_stride);
        return uploadMap(slot, src, src_stride);
    }

    fn uploadVulkan(self: *Self, slot: *Slot, src: []const u8, src_stride: u32) bool {
        const bytes = requiredStaging(src_stride, slot.height);
        if (src.len < bytes) return false;
        if (!self.stagingFits(bytes)) return false;
        @memcpy(self.staging_map[0..bytes], src[0..bytes]);
        return self.submitCopy(slot, src_stride);
    }

    fn submitCopy(self: *Self, slot: *const Slot, src_stride: u32) bool {
        return self.submitRecord(recordCopyFn, slot, src_stride);
    }

    fn clearSlot(self: *Self, slot: *const Slot) bool {
        if (slot.image == null) return true;
        return self.submitRecord(recordClearFn, slot, 0);
    }

    fn submitRecord(
        self: *Self,
        record: *const fn (vk.VkCommandBuffer, *const Slot, vk.VkBuffer, u32) void,
        slot: *const Slot,
        src_stride: u32,
    ) bool {
        if (vk.vkResetFences(self.device, 1, &self.fence) != vk.VK_SUCCESS) return false;
        if (vk.vkResetCommandBuffer(self.command_buffer, 0) != vk.VK_SUCCESS) return false;
        if (!beginOneShot(self.command_buffer)) return false;
        record(self.command_buffer, slot, self.staging, src_stride);
        if (vk.vkEndCommandBuffer(self.command_buffer) != vk.VK_SUCCESS) return false;
        return submitAndWait(self.device, self.queue, self.command_buffer, self.fence);
    }

    fn stagingFits(self: *const Self, size: usize) bool {
        return self.staging_size >= size and self.staging_map.len >= size;
    }

    /// Control plane only: size the host staging buffer.
    fn growStaging(self: *Self, size: usize) bool {
        if (self.stagingFits(size)) return true;
        self.destroyStaging();
        const created = createHostBuffer(self.device, self.physical, size) orelse return false;
        self.staging = created.buffer;
        self.staging_memory = created.memory;
        self.staging_size = created.size;
        self.staging_map = created.map;
        return true;
    }

    fn destroyStaging(self: *Self) void {
        if (self.staging_map.len != 0) {
            vk.vkUnmapMemory(self.device, self.staging_memory);
            self.staging_map = &.{};
        }
        if (self.staging != null) vk.vkDestroyBuffer(self.device, self.staging, null);
        if (self.staging_memory != null) vk.vkFreeMemory(self.device, self.staging_memory, null);
        self.staging = null;
        self.staging_memory = null;
        self.staging_size = 0;
    }

    fn importSlotImage(self: *Self, slot: *Slot, bo: *gbm.struct_gbm_bo) void {
        const imported = importBoImage(self.device, self.physical, bo) orelse return;
        slot.image = imported.image;
        slot.memory = imported.memory;
    }
};

pub fn slotReady(slot: Slot, width: u32, height: u32, format: u32) bool {
    if (slot.fb_id == 0 or slot.width != width or slot.height != height) return false;
    return format == 0 or slot.format == format;
}

pub const DevIds = struct { major: u32, minor: u32 };

pub fn linuxDevParts(rdev: u64) DevIds {
    return .{
        .major = @intCast((rdev >> 8) & 0xfff),
        .minor = @intCast((rdev & 0xff) | ((rdev >> 12) & 0xfff00)),
    };
}

pub fn drmNodeMatches(
    has_node: u32,
    node_major: i64,
    node_minor: i64,
    fd_major: u32,
    fd_minor: u32,
) bool {
    if (has_node == vk.VK_FALSE) return false;
    return node_major == fd_major and node_minor == fd_minor;
}

pub fn vkFormat(fourcc: u32) ?vk.VkFormat {
    return switch (fourcc) {
        drm_format.XRGB8888, drm_format.ARGB8888 => vk.VK_FORMAT_B8G8R8A8_UNORM,
        drm_format.XBGR8888, drm_format.ABGR8888 => vk.VK_FORMAT_R8G8B8A8_UNORM,
        else => null,
    };
}

const posix_stat = @cImport({
    @cInclude("sys/stat.h");
});

fn fdDevIds(fd: i32) !DevIds {
    var st: posix_stat.struct_stat = undefined;
    if (posix_stat.fstat(fd, &st) != 0) return error.StatFailed;
    return linuxDevParts(@intCast(st.st_rdev));
}

fn createInstance() !vk.VkInstance {
    var app = std.mem.zeroes(vk.VkApplicationInfo);
    app.sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app.pApplicationName = "sideswipe";
    app.applicationVersion = vk.VK_MAKE_VERSION(0, 1, 0);
    app.pEngineName = "sideswipe";
    app.engineVersion = vk.VK_MAKE_VERSION(0, 1, 0);
    app.apiVersion = vk.VK_API_VERSION_1_1;
    const ext: [*:0]const u8 = instance_ext_drm;
    var info = std.mem.zeroes(vk.VkInstanceCreateInfo);
    info.sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    info.pApplicationInfo = &app;
    info.enabledExtensionCount = 1;
    info.ppEnabledExtensionNames = @ptrCast(&ext);
    var instance: vk.VkInstance = null;
    if (vk.vkCreateInstance(&info, null, &instance) != vk.VK_SUCCESS) return error.VulkanInstance;
    return instance;
}

fn pickPhysicalDevice(instance: vk.VkInstance, ids: DevIds) !vk.VkPhysicalDevice {
    var count: u32 = 0;
    if (vk.vkEnumeratePhysicalDevices(instance, &count, null) != vk.VK_SUCCESS or count == 0)
        return error.NoVulkanDevice;
    var stack: [8]vk.VkPhysicalDevice = undefined;
    const devices = stack[0..cappedLen(count, stack.len)];
    var listed: u32 = @intCast(devices.len);
    if (vk.vkEnumeratePhysicalDevices(instance, &listed, devices.ptr) != vk.VK_SUCCESS)
        return error.NoVulkanDevice;
    return firstMatchingDevice(devices[0..listed], ids) orelse error.NoVulkanDevice;
}

fn cappedLen(count: u32, cap: usize) usize {
    return @min(count, cap);
}

fn firstMatchingDevice(
    devices: []const vk.VkPhysicalDevice,
    ids: DevIds,
) ?vk.VkPhysicalDevice {
    for (devices) |device| {
        if (physicalMatches(device, ids)) return device;
    }
    return null;
}

fn physicalMatches(device: vk.VkPhysicalDevice, ids: DevIds) bool {
    var drm_props = std.mem.zeroes(vk.VkPhysicalDeviceDrmPropertiesEXT);
    drm_props.sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRM_PROPERTIES_EXT;
    var props = std.mem.zeroes(vk.VkPhysicalDeviceProperties2);
    props.sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2;
    props.pNext = &drm_props;
    vk.vkGetPhysicalDeviceProperties2(device, &props);
    return drmNodeMatches(drm_props.hasRender, drm_props.renderMajor, drm_props.renderMinor, ids.major, ids.minor) or
        drmNodeMatches(drm_props.hasPrimary, drm_props.primaryMajor, drm_props.primaryMinor, ids.major, ids.minor);
}

fn findGraphicsQueue(physical: vk.VkPhysicalDevice) !u32 {
    var count: u32 = 0;
    vk.vkGetPhysicalDeviceQueueFamilyProperties(physical, &count, null);
    var stack: [8]vk.VkQueueFamilyProperties = undefined;
    const families = stack[0..cappedLen(count, stack.len)];
    var listed: u32 = @intCast(families.len);
    vk.vkGetPhysicalDeviceQueueFamilyProperties(physical, &listed, families.ptr);
    for (families[0..listed], 0..) |family, index| {
        if ((family.queueFlags & vk.VK_QUEUE_GRAPHICS_BIT) != 0) return @intCast(index);
    }
    return error.NoGraphicsQueue;
}

fn createLogicalDevice(physical: vk.VkPhysicalDevice, family: u32) !vk.VkDevice {
    const priority: f32 = 1.0;
    var queue_info = std.mem.zeroes(vk.VkDeviceQueueCreateInfo);
    queue_info.sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    queue_info.queueFamilyIndex = family;
    queue_info.queueCount = 1;
    queue_info.pQueuePriorities = &priority;
    const extensions = [_][*:0]const u8{ device_ext_mem_fd, device_ext_dma_buf, device_ext_modifier };
    var info = std.mem.zeroes(vk.VkDeviceCreateInfo);
    info.sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    info.queueCreateInfoCount = 1;
    info.pQueueCreateInfos = &queue_info;
    info.enabledExtensionCount = extensions.len;
    info.ppEnabledExtensionNames = &extensions;
    var device: vk.VkDevice = null;
    if (vk.vkCreateDevice(physical, &info, null, &device) != vk.VK_SUCCESS) return error.VulkanDevice;
    return device;
}

fn createCommandPool(device: vk.VkDevice, family: u32) !vk.VkCommandPool {
    var info = std.mem.zeroes(vk.VkCommandPoolCreateInfo);
    info.sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    info.flags = vk.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    info.queueFamilyIndex = family;
    var pool: vk.VkCommandPool = null;
    if (vk.vkCreateCommandPool(device, &info, null, &pool) != vk.VK_SUCCESS) return error.VulkanCommandPool;
    return pool;
}

fn allocateCommandBuffer(device: vk.VkDevice, pool: vk.VkCommandPool) !vk.VkCommandBuffer {
    var info = std.mem.zeroes(vk.VkCommandBufferAllocateInfo);
    info.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    info.commandPool = pool;
    info.level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    info.commandBufferCount = 1;
    var buffer: vk.VkCommandBuffer = null;
    if (vk.vkAllocateCommandBuffers(device, &info, &buffer) != vk.VK_SUCCESS) return error.VulkanCommandBuffer;
    return buffer;
}

fn createFence(device: vk.VkDevice) !vk.VkFence {
    var info = std.mem.zeroes(vk.VkFenceCreateInfo);
    info.sType = vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    info.flags = vk.VK_FENCE_CREATE_SIGNALED_BIT;
    var fence: vk.VkFence = null;
    if (vk.vkCreateFence(device, &info, null, &fence) != vk.VK_SUCCESS) return error.VulkanFence;
    return fence;
}

fn createBo(
    device: *gbm.struct_gbm_device,
    width: u32,
    height: u32,
    format: u32,
    modifiers: []const u64,
) ?*gbm.struct_gbm_bo {
    const flags: u32 = gbm.GBM_BO_USE_RENDERING | gbm.GBM_BO_USE_SCANOUT;
    if (modifiers.len != 0) {
        if (gbm.gbm_bo_create_with_modifiers2(device, width, height, format, modifiers.ptr, @intCast(modifiers.len), flags)) |bo|
            return bo;
    }
    return gbm.gbm_bo_create(device, width, height, format, flags);
}

fn addSlotFb(drm_fd: i32, bo: *gbm.struct_gbm_bo, width: u32, height: u32, format: u32, allow_modifiers: bool) ?u32 {
    const planes = boPlanes(bo);
    const count: usize = @intCast(@max(gbm.gbm_bo_get_plane_count(bo), 1));
    return drm_fb.add(drm_fd, width, height, format, &planes, count, allow_modifiers);
}

fn boPlanes(bo: *gbm.struct_gbm_bo) drm_fb.Planes {
    var planes = drm_fb.Planes{};
    const count: usize = @intCast(@min(@max(gbm.gbm_bo_get_plane_count(bo), 1), 4));
    const modifier = gbm.gbm_bo_get_modifier(bo);
    for (0..count) |index| {
        planes.handles[index] = gbm.gbm_bo_get_handle_for_plane(bo, @intCast(index)).u32;
        planes.pitches[index] = gbm.gbm_bo_get_stride_for_plane(bo, @intCast(index));
        planes.offsets[index] = gbm.gbm_bo_get_offset(bo, @intCast(index));
        planes.modifiers[index] = modifier;
    }
    return planes;
}

const ImportedImage = struct {
    image: vk.VkImage,
    memory: vk.VkDeviceMemory,
};

fn importBoImage(device: vk.VkDevice, physical: vk.VkPhysicalDevice, bo: *gbm.struct_gbm_bo) ?ImportedImage {
    const fd = gbm.gbm_bo_get_fd(bo);
    if (fd < 0) return null;
    const image = createImportImage(device, bo) orelse {
        core.unix.close(fd);
        return null;
    };
    const memory = importImageMemory(device, physical, image, fd) orelse {
        vk.vkDestroyImage(device, image, null);
        core.unix.close(fd);
        return null;
    };
    if (vk.vkBindImageMemory(device, image, memory, 0) != vk.VK_SUCCESS) {
        vk.vkDestroyImage(device, image, null);
        vk.vkFreeMemory(device, memory, null);
        return null;
    }
    return .{ .image = image, .memory = memory };
}

fn createImportImage(device: vk.VkDevice, bo: *gbm.struct_gbm_bo) ?vk.VkImage {
    var layouts = planeLayouts(bo);
    const plane_count: u32 = @intCast(@min(@max(gbm.gbm_bo_get_plane_count(bo), 1), 4));
    var modifier_info = std.mem.zeroes(vk.VkImageDrmFormatModifierExplicitCreateInfoEXT);
    modifier_info.sType = vk.VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_EXPLICIT_CREATE_INFO_EXT;
    modifier_info.drmFormatModifier = gbm.gbm_bo_get_modifier(bo);
    modifier_info.drmFormatModifierPlaneCount = plane_count;
    modifier_info.pPlaneLayouts = &layouts;
    var external = std.mem.zeroes(vk.VkExternalMemoryImageCreateInfo);
    external.sType = vk.VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO;
    external.pNext = &modifier_info;
    external.handleTypes = vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT;
    var info = std.mem.zeroes(vk.VkImageCreateInfo);
    info.sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    info.pNext = &external;
    info.imageType = vk.VK_IMAGE_TYPE_2D;
    info.format = vkFormat(gbm.gbm_bo_get_format(bo)) orelse return null;
    info.extent = .{ .width = gbm.gbm_bo_get_width(bo), .height = gbm.gbm_bo_get_height(bo), .depth = 1 };
    info.mipLevels = 1;
    info.arrayLayers = 1;
    info.samples = vk.VK_SAMPLE_COUNT_1_BIT;
    info.tiling = vk.VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT;
    info.usage = vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    info.sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE;
    info.initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED;
    var image: vk.VkImage = null;
    if (vk.vkCreateImage(device, &info, null, &image) != vk.VK_SUCCESS) return null;
    return image;
}

fn planeLayouts(bo: *gbm.struct_gbm_bo) [4]vk.VkSubresourceLayout {
    var layouts = std.mem.zeroes([4]vk.VkSubresourceLayout);
    const count: usize = @intCast(@min(@max(gbm.gbm_bo_get_plane_count(bo), 1), 4));
    for (0..count) |index| {
        layouts[index] = .{
            .offset = gbm.gbm_bo_get_offset(bo, @intCast(index)),
            .size = 0,
            .rowPitch = gbm.gbm_bo_get_stride_for_plane(bo, @intCast(index)),
            .arrayPitch = 0,
            .depthPitch = 0,
        };
    }
    return layouts;
}

fn importImageMemory(device: vk.VkDevice, physical: vk.VkPhysicalDevice, image: vk.VkImage, fd: i32) ?vk.VkDeviceMemory {
    var reqs = std.mem.zeroes(vk.VkMemoryRequirements);
    vk.vkGetImageMemoryRequirements(device, image, &reqs);
    var fd_props = std.mem.zeroes(vk.VkMemoryFdPropertiesKHR);
    fd_props.sType = vk.VK_STRUCTURE_TYPE_MEMORY_FD_PROPERTIES_KHR;
    if (getMemoryFdProperties(device, fd, &fd_props) != vk.VK_SUCCESS)
        return null;
    const type_index = memoryTypeIndex(physical, reqs.memoryTypeBits & fd_props.memoryTypeBits, 0) orelse return null;
    var import = std.mem.zeroes(vk.VkImportMemoryFdInfoKHR);
    import.sType = vk.VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR;
    import.handleType = vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT;
    import.fd = fd;
    var dedicated = std.mem.zeroes(vk.VkMemoryDedicatedAllocateInfo);
    dedicated.sType = vk.VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO;
    dedicated.pNext = &import;
    dedicated.image = image;
    var info = std.mem.zeroes(vk.VkMemoryAllocateInfo);
    info.sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    info.pNext = &dedicated;
    info.allocationSize = reqs.size;
    info.memoryTypeIndex = type_index;
    var memory: vk.VkDeviceMemory = null;
    if (vk.vkAllocateMemory(device, &info, null, &memory) != vk.VK_SUCCESS) return null;
    return memory;
}

const HostBuffer = struct {
    buffer: vk.VkBuffer,
    memory: vk.VkDeviceMemory,
    size: vk.VkDeviceSize,
    map: []u8,
};

fn createHostBuffer(device: vk.VkDevice, physical: vk.VkPhysicalDevice, size: usize) ?HostBuffer {
    var info = std.mem.zeroes(vk.VkBufferCreateInfo);
    info.sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    info.size = size;
    info.usage = vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
    info.sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE;
    var buffer: vk.VkBuffer = null;
    if (vk.vkCreateBuffer(device, &info, null, &buffer) != vk.VK_SUCCESS) return null;
    var reqs = std.mem.zeroes(vk.VkMemoryRequirements);
    vk.vkGetBufferMemoryRequirements(device, buffer, &reqs);
    const flags = vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    const type_index = memoryTypeIndex(physical, reqs.memoryTypeBits, flags) orelse {
        vk.vkDestroyBuffer(device, buffer, null);
        return null;
    };
    return bindHostBuffer(device, buffer, reqs.size, type_index);
}

fn bindHostBuffer(device: vk.VkDevice, buffer: vk.VkBuffer, size: vk.VkDeviceSize, type_index: u32) ?HostBuffer {
    var info = std.mem.zeroes(vk.VkMemoryAllocateInfo);
    info.sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    info.allocationSize = size;
    info.memoryTypeIndex = type_index;
    var memory: vk.VkDeviceMemory = null;
    if (vk.vkAllocateMemory(device, &info, null, &memory) != vk.VK_SUCCESS) {
        vk.vkDestroyBuffer(device, buffer, null);
        return null;
    }
    if (vk.vkBindBufferMemory(device, buffer, memory, 0) != vk.VK_SUCCESS) {
        vk.vkFreeMemory(device, memory, null);
        vk.vkDestroyBuffer(device, buffer, null);
        return null;
    }
    var mapped: ?*anyopaque = null;
    if (vk.vkMapMemory(device, memory, 0, size, 0, &mapped) != vk.VK_SUCCESS) {
        vk.vkFreeMemory(device, memory, null);
        vk.vkDestroyBuffer(device, buffer, null);
        return null;
    }
    const ptr: [*]u8 = @ptrCast(mapped.?);
    return .{ .buffer = buffer, .memory = memory, .size = size, .map = ptr[0..@intCast(size)] };
}

const GetMemoryFdProperties = *const fn (
    device: vk.VkDevice,
    handle_type: vk.VkExternalMemoryHandleTypeFlagBits,
    fd: c_int,
    props: *vk.VkMemoryFdPropertiesKHR,
) callconv(.c) vk.VkResult;

fn getMemoryFdProperties(device: vk.VkDevice, fd: i32, props: *vk.VkMemoryFdPropertiesKHR) vk.VkResult {
    const loaded = vk.vkGetDeviceProcAddr(device, "vkGetMemoryFdPropertiesKHR") orelse
        return vk.VK_ERROR_EXTENSION_NOT_PRESENT;
    const func: GetMemoryFdProperties = @ptrCast(loaded);
    return func(device, vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT, fd, props);
}

fn memoryTypeIndex(physical: vk.VkPhysicalDevice, type_bits: u32, flags: vk.VkMemoryPropertyFlags) ?u32 {
    var props = std.mem.zeroes(vk.VkPhysicalDeviceMemoryProperties);
    vk.vkGetPhysicalDeviceMemoryProperties(physical, &props);
    var index: u32 = 0;
    while (index < props.memoryTypeCount) : (index += 1) {
        if ((type_bits & (@as(u32, 1) << @intCast(index))) == 0) continue;
        if ((props.memoryTypes[index].propertyFlags & flags) != flags) continue;
        return index;
    }
    return null;
}

fn beginOneShot(command_buffer: vk.VkCommandBuffer) bool {
    var info = std.mem.zeroes(vk.VkCommandBufferBeginInfo);
    info.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    info.flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    return vk.vkBeginCommandBuffer(command_buffer, &info) == vk.VK_SUCCESS;
}

fn recordCopyFn(
    command_buffer: vk.VkCommandBuffer,
    slot: *const Slot,
    buffer: vk.VkBuffer,
    src_stride: u32,
) void {
    const image = slot.image orelse return;
    barrierTransferDst(command_buffer, image, vk.VK_IMAGE_LAYOUT_UNDEFINED, 0);
    var region = std.mem.zeroes(vk.VkBufferImageCopy);
    region.bufferRowLength = src_stride / 4;
    region.imageSubresource = colorSubresource();
    region.imageExtent = .{ .width = slot.width, .height = slot.height, .depth = 1 };
    vk.vkCmdCopyBufferToImage(command_buffer, buffer, image, vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
    barrierGeneral(command_buffer, image);
}

fn recordClearFn(
    command_buffer: vk.VkCommandBuffer,
    slot: *const Slot,
    _: vk.VkBuffer,
    _: u32,
) void {
    const image = slot.image orelse return;
    barrierTransferDst(command_buffer, image, vk.VK_IMAGE_LAYOUT_UNDEFINED, 0);
    var color = std.mem.zeroes(vk.VkClearColorValue);
    const range = colorRange();
    vk.vkCmdClearColorImage(command_buffer, image, vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &color, 1, &range);
    barrierGeneral(command_buffer, image);
}

fn barrierTransferDst(
    command_buffer: vk.VkCommandBuffer,
    image: vk.VkImage,
    old_layout: vk.VkImageLayout,
    src_access: vk.VkAccessFlags,
) void {
    var barrier = imageBarrier(image, old_layout, vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, src_access, vk.VK_ACCESS_TRANSFER_WRITE_BIT);
    vk.vkCmdPipelineBarrier(
        command_buffer,
        vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
        0,
        0,
        null,
        0,
        null,
        1,
        &barrier,
    );
}

fn barrierGeneral(command_buffer: vk.VkCommandBuffer, image: vk.VkImage) void {
    var barrier = imageBarrier(
        image,
        vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        vk.VK_IMAGE_LAYOUT_GENERAL,
        vk.VK_ACCESS_TRANSFER_WRITE_BIT,
        0,
    );
    vk.vkCmdPipelineBarrier(
        command_buffer,
        vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
        vk.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
        0,
        0,
        null,
        0,
        null,
        1,
        &barrier,
    );
}

fn imageBarrier(
    image: vk.VkImage,
    old_layout: vk.VkImageLayout,
    new_layout: vk.VkImageLayout,
    src_access: vk.VkAccessFlags,
    dst_access: vk.VkAccessFlags,
) vk.VkImageMemoryBarrier {
    var barrier = std.mem.zeroes(vk.VkImageMemoryBarrier);
    barrier.sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    barrier.srcAccessMask = src_access;
    barrier.dstAccessMask = dst_access;
    barrier.oldLayout = old_layout;
    barrier.newLayout = new_layout;
    barrier.srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED;
    barrier.image = image;
    barrier.subresourceRange = colorRange();
    return barrier;
}

fn colorRange() vk.VkImageSubresourceRange {
    var range = std.mem.zeroes(vk.VkImageSubresourceRange);
    range.aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT;
    range.levelCount = 1;
    range.layerCount = 1;
    return range;
}

fn colorSubresource() vk.VkImageSubresourceLayers {
    var layers = std.mem.zeroes(vk.VkImageSubresourceLayers);
    layers.aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT;
    layers.layerCount = 1;
    return layers;
}

fn submitAndWait(
    device: vk.VkDevice,
    queue: vk.VkQueue,
    command_buffer: vk.VkCommandBuffer,
    fence: vk.VkFence,
) bool {
    var submit = std.mem.zeroes(vk.VkSubmitInfo);
    submit.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submit.commandBufferCount = 1;
    submit.pCommandBuffers = &command_buffer;
    if (vk.vkQueueSubmit(queue, 1, &submit, fence) != vk.VK_SUCCESS) return false;
    return vk.vkWaitForFences(device, 1, &fence, vk.VK_TRUE, std.math.maxInt(u64)) == vk.VK_SUCCESS;
}

fn uploadMap(slot: *Slot, src: []const u8, src_stride: u32) bool {
    const bytes = requiredStaging(src_stride, slot.height);
    if (src.len < bytes) return false;
    const bo = slot.bo orelse return false;
    var map_stride: u32 = 0;
    var map_data: ?*anyopaque = null;
    const mapped = gbm.gbm_bo_map(
        bo,
        0,
        0,
        slot.width,
        slot.height,
        gbm.GBM_BO_TRANSFER_WRITE,
        &map_stride,
        &map_data,
    ) orelse return false;
    defer gbm.gbm_bo_unmap(bo, map_data);
    const dest_bytes = requiredStaging(map_stride, slot.height);
    const dest: [*]u8 = @ptrCast(mapped);
    return copyRows(dest[0..dest_bytes], map_stride, src, src_stride, slot.width, slot.height);
}

fn copyRows(dest: []u8, dest_stride: u32, src: []const u8, src_stride: u32, width: u32, height: u32) bool {
    const row_bytes: usize = @as(usize, width) * 4;
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const src_off: usize = @as(usize, y) * src_stride;
        const dst_off: usize = @as(usize, y) * dest_stride;
        if (src_off + row_bytes > src.len or dst_off + row_bytes > dest.len) return false;
        @memcpy(dest[dst_off..][0..row_bytes], src[src_off..][0..row_bytes]);
    }
    return true;
}

fn scanoutStrideOk(stride: u32, width: u32) bool {
    const min_stride: u64 = @as(u64, width) * 4;
    return stride >= min_stride and stride % 4 == 0;
}

fn requiredStaging(stride: u32, height: u32) usize {
    return @as(usize, stride) * @as(usize, height);
}

fn stagingBytes(width: u32, height: u32) usize {
    const stride = std.mem.alignForward(u32, width * 4, 256);
    return requiredStaging(stride, height);
}

fn drmRmFb(drm_fd: i32, fb_id: u32) void {
    drm_fb.remove(drm_fd, fb_id);
}

const testing = core.testing;

test "slotReady - requires fb, size, and format" {
    try testing.expect(!slotReady(.{}, 1920, 1080, drm_format.XRGB8888));
    try testing.expect(slotReady(.{ .fb_id = 1, .width = 1920, .height = 1080, .format = drm_format.XRGB8888 }, 1920, 1080, drm_format.XRGB8888));
    try testing.expect(!slotReady(.{ .fb_id = 1, .width = 1920, .height = 1080, .format = drm_format.XRGB8888 }, 1920, 1080, drm_format.ARGB8888));
}

test "linuxDevParts - splits a typical render-node rdev" {
    const parts = linuxDevParts(0xE201);
    try testing.expectEqual(@as(u32, 0xe2), parts.major);
    try testing.expectEqual(@as(u32, 1), parts.minor);
}

test "drmNodeMatches - render node must be advertised" {
    try testing.expect(!drmNodeMatches(vk.VK_FALSE, 226, 128, 226, 128));
    try testing.expect(drmNodeMatches(vk.VK_TRUE, 226, 128, 226, 128));
    try testing.expect(!drmNodeMatches(vk.VK_TRUE, 226, 128, 226, 129));
}

test "vkFormat - packed 8888 maps to BGRA or RGBA" {
    try testing.expectEqual(@as(vk.VkFormat, vk.VK_FORMAT_B8G8R8A8_UNORM), vkFormat(drm_format.XRGB8888).?);
    try testing.expectEqual(@as(vk.VkFormat, vk.VK_FORMAT_R8G8B8A8_UNORM), vkFormat(drm_format.XBGR8888).?);
    try testing.expect(vkFormat(0xDEADBEEF) == null);
}

test "requiredStaging - stride times height" {
    try testing.expectEqual(@as(usize, 7680 * 1080), requiredStaging(7680, 1080));
}

test "stagingBytes - aligns pitch to 256" {
    try testing.expectEqual(@as(usize, 7680 * 1080), stagingBytes(1920, 1080));
    try testing.expectEqual(@as(usize, 512 * 10), stagingBytes(100, 10));
}

test "scanoutStrideOk - packed 8888 and aligned extra pitch" {
    try testing.expect(scanoutStrideOk(7680, 1920));
    try testing.expect(scanoutStrideOk(8192, 1920));
    try testing.expect(!scanoutStrideOk(7679, 1920));
    try testing.expect(!scanoutStrideOk(7681, 1920));
}

test "copyRows - copies a packed BGRA row and rejects a short source" {
    var dest = [_]u8{0} ** 16;
    const src = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    try testing.expect(copyRows(&dest, 8, &src, 8, 2, 1));
    try testing.expectEqualSlices(u8, src[0..8], dest[0..8]);
    try testing.expect(!copyRows(&dest, 8, src[0..4], 8, 2, 1));
}

test "cappedLen - never exceeds the stack slot count" {
    try testing.expectEqual(@as(usize, 8), cappedLen(32, 8));
    try testing.expectEqual(@as(usize, 3), cappedLen(3, 8));
}

test "Device.create - invalid fds fail before instance setup" {
    try testing.expectError(error.InvalidDrmFd, Device.create(testing.allocator, -1, -1));
}
