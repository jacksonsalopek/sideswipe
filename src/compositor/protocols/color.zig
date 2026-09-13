//! wp_color_management_v1 and wp_color_representation_v1 (H5–H7).

const wayland = @import("wayland");
const c = wayland.c;
const Compositor = @import("../compositor.zig").Compositor;
const Surface = @import("../surface.zig").Surface;
const SurfaceData = @import("compositor.zig").SurfaceData;
const color = @import("../color.zig");

const VERSION: u32 = 3;

const Description = struct {
    compositor: *Compositor,
    intent: color.Intent,
    ready: bool = true,
    identity: u32,
};

fn managerDestroy(_: ?*c.wl_client, resource: ?*c.wl_resource) callconv(.c) void {
    c.wl_resource_destroy(resource);
}

/// Single advertised `wl_output` is outputs[0]; per-output globals are not M6.
fn getOutput(
    _: ?*c.wl_client,
    resource: ?*c.wl_resource,
    id: u32,
    _: ?*c.wl_resource,
) callconv(.c) void {
    const compositor: *Compositor = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
    const created = c.wl_resource_create(
        c.wl_resource_get_client(resource orelse return),
        &c.wp_color_management_output_v1_interface,
        c.wl_resource_get_version(resource),
        id,
    ) orelse return c.wl_resource_post_no_memory(resource);
    c.wl_resource_set_implementation(created, @ptrCast(&output_impl), compositor, null);
}

fn getSurface(
    _: ?*c.wl_client,
    resource: ?*c.wl_resource,
    id: u32,
    surface_resource: ?*c.wl_resource,
) callconv(.c) void {
    const surface = userdata(SurfaceData, surface_resource orelse return).surface;
    if (surface.color_surface != null) {
        c.wl_resource_post_error(
            resource,
            c.WP_COLOR_MANAGER_V1_ERROR_SURFACE_EXISTS,
            "color management surface already exists",
        );
        return;
    }
    const created = c.wl_resource_create(
        c.wl_resource_get_client(resource orelse return),
        &c.wp_color_management_surface_v1_interface,
        c.wl_resource_get_version(resource),
        id,
    ) orelse return c.wl_resource_post_no_memory(resource);
    surface.color_surface = created;
    c.wl_resource_set_implementation(created, @ptrCast(&surface_impl), surface, colorSurfaceDestroy);
}

fn getFeedback(
    _: ?*c.wl_client,
    resource: ?*c.wl_resource,
    id: u32,
    _: ?*c.wl_resource,
) callconv(.c) void {
    const compositor: *Compositor = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
    const created = c.wl_resource_create(
        c.wl_resource_get_client(resource orelse return),
        &c.wp_color_management_surface_feedback_v1_interface,
        c.wl_resource_get_version(resource),
        id,
    ) orelse return c.wl_resource_post_no_memory(resource);
    c.wl_resource_set_implementation(created, @ptrCast(&feedback_impl), compositor, null);
}

fn unsupportedCreator(_: ?*c.wl_client, resource: ?*c.wl_resource, _: u32) callconv(.c) void {
    c.wl_resource_post_error(
        resource,
        c.WP_COLOR_MANAGER_V1_ERROR_UNSUPPORTED_FEATURE,
        "image description creator is not advertised",
    );
}

fn createNamed(
    _: ?*c.wl_client,
    resource: ?*c.wl_resource,
    id: u32,
    intent: color.Intent,
) void {
    const compositor: *Compositor = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
    sendReady(compositor, resource orelse return, id, intent);
}

fn createWindowsScrgb(client: ?*c.wl_client, resource: ?*c.wl_resource, id: u32) callconv(.c) void {
    _ = client;
    createNamed(null, resource, id, .{ .transfer = .scrgb });
}

fn createParametricCreator(_: ?*c.wl_client, resource: ?*c.wl_resource, id: u32) callconv(.c) void {
    const compositor: *Compositor = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
    const created = c.wl_resource_create(
        c.wl_resource_get_client(resource orelse return),
        &c.wp_image_description_creator_params_v1_interface,
        c.wl_resource_get_version(resource),
        id,
    ) orelse return c.wl_resource_post_no_memory(resource);
    const params = compositor.allocator.create(Params) catch {
        c.wl_resource_destroy(created);
        return c.wl_resource_post_no_memory(resource);
    };
    params.* = .{ .compositor = compositor, .resource = created };
    c.wl_resource_set_implementation(created, @ptrCast(&params_impl), params, destroyParams);
}

fn createWindowsBt2100(client: ?*c.wl_client, resource: ?*c.wl_resource, id: u32) callconv(.c) void {
    _ = client;
    createNamed(null, resource, id, .{ .transfer = .pq, .bt2020 = true });
}

fn getImageDescription(
    _: ?*c.wl_client,
    resource: ?*c.wl_resource,
    id: u32,
    _: ?*c.wl_resource,
) callconv(.c) void {
    const compositor: *Compositor = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
    sendReady(compositor, resource orelse return, id, color.Intent.sdr());
}

fn sendReady(compositor: *Compositor, parent: *c.wl_resource, id: u32, intent: color.Intent) void {
    const created = c.wl_resource_create(
        c.wl_resource_get_client(parent),
        &c.wp_image_description_v1_interface,
        c.wl_resource_get_version(parent),
        id,
    ) orelse return c.wl_resource_post_no_memory(parent);
    const description = compositor.allocator.create(Description) catch {
        c.wl_resource_destroy(created);
        return c.wl_resource_post_no_memory(parent);
    };
    compositor.next_image_description +%= 1;
    description.* = .{
        .compositor = compositor,
        .intent = intent,
        .identity = compositor.next_image_description,
    };
    c.wl_resource_set_implementation(created, @ptrCast(&description_impl), description, destroyDescription);
    announceReady(created, description.identity);
}

fn announceReady(resource: *c.wl_resource, identity: u32) void {
    if (c.wl_resource_get_version(resource) >= 2) {
        c.wp_image_description_v1_send_ready2(resource, 0, identity);
        return;
    }
    c.wp_image_description_v1_send_ready(resource, identity);
}

fn outputDestroy(_: ?*c.wl_client, resource: ?*c.wl_resource) callconv(.c) void {
    c.wl_resource_destroy(resource);
}

fn outputGetDescription(_: ?*c.wl_client, resource: ?*c.wl_resource, id: u32) callconv(.c) void {
    const compositor: *Compositor = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
    const intent = outputIntent(compositor);
    sendReady(compositor, resource orelse return, id, intent);
}

fn outputIntent(compositor: *Compositor) color.Intent {
    if (compositor.outputs.items.len == 0) return color.Intent.sdr();
    const output = compositor.outputs.items[0];
    return color.preferredIntent(output.hdr_caps, output.hdr_engaged);
}

fn surfaceDestroyReq(_: ?*c.wl_client, resource: ?*c.wl_resource) callconv(.c) void {
    c.wl_resource_destroy(resource);
}

fn setImageDescription(
    _: ?*c.wl_client,
    resource: ?*c.wl_resource,
    description_resource: ?*c.wl_resource,
    _: u32,
) callconv(.c) void {
    const surface: *Surface = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
    const description = userdata(Description, description_resource orelse return);
    if (!description.ready) {
        c.wl_resource_post_error(
            resource,
            c.WP_COLOR_MANAGEMENT_SURFACE_V1_ERROR_IMAGE_DESCRIPTION,
            "image description is not ready",
        );
        return;
    }
    surface.pending_color_intent = description.intent;
}

fn unsetImageDescription(_: ?*c.wl_client, resource: ?*c.wl_resource) callconv(.c) void {
    const surface: *Surface = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
    surface.pending_color_intent = color.Intent.sdr();
}

fn colorSurfaceDestroy(resource: ?*c.wl_resource) callconv(.c) void {
    const surface: *Surface = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
    surface.color_surface = null;
    surface.pending_color_intent = color.Intent.sdr();
    surface.color_intent = color.Intent.sdr();
}

fn feedbackDestroy(_: ?*c.wl_client, resource: ?*c.wl_resource) callconv(.c) void {
    c.wl_resource_destroy(resource);
}

fn feedbackGetPreferred(_: ?*c.wl_client, resource: ?*c.wl_resource, id: u32) callconv(.c) void {
    const compositor: *Compositor = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
    sendReady(compositor, resource orelse return, id, outputIntent(compositor));
}

fn feedbackGetPreferredParametric(client: ?*c.wl_client, resource: ?*c.wl_resource, id: u32) callconv(.c) void {
    feedbackGetPreferred(client, resource, id);
}

fn descriptionDestroy(_: ?*c.wl_client, resource: ?*c.wl_resource) callconv(.c) void {
    c.wl_resource_destroy(resource);
}

fn descriptionGetInformation(_: ?*c.wl_client, resource: ?*c.wl_resource, id: u32) callconv(.c) void {
    const description = userdata(Description, resource orelse return);
    const info = c.wl_resource_create(
        c.wl_resource_get_client(resource.?),
        &c.wp_image_description_info_v1_interface,
        c.wl_resource_get_version(resource),
        id,
    ) orelse return c.wl_resource_post_no_memory(resource);
    const primaries: u32 = if (description.intent.bt2020)
        c.WP_COLOR_MANAGER_V1_PRIMARIES_BT2020
    else
        c.WP_COLOR_MANAGER_V1_PRIMARIES_SRGB;
    const tf: u32 = switch (description.intent.transfer) {
        .pq => c.WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_ST2084_PQ,
        .hlg => c.WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_HLG,
        .scrgb => c.WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_EXT_LINEAR,
        .sdr => c.WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_GAMMA22,
    };
    c.wp_image_description_info_v1_send_primaries_named(info, primaries);
    c.wp_image_description_info_v1_send_tf_named(info, tf);
    c.wp_image_description_info_v1_send_done(info);
}

fn destroyDescription(resource: ?*c.wl_resource) callconv(.c) void {
    const description = userdata(Description, resource orelse return);
    description.compositor.allocator.destroy(description);
}

var manager_impl = [_]?*const anyopaque{
    @ptrCast(&managerDestroy),
    @ptrCast(&getOutput),
    @ptrCast(&getSurface),
    @ptrCast(&getFeedback),
    @ptrCast(&unsupportedCreator),
    @ptrCast(&createParametricCreator),
    @ptrCast(&createWindowsScrgb),
    @ptrCast(&getImageDescription),
    @ptrCast(&createWindowsBt2100),
};

var output_impl = [_]?*const anyopaque{
    @ptrCast(&outputDestroy),
    @ptrCast(&outputGetDescription),
};

var surface_impl = [_]?*const anyopaque{
    @ptrCast(&surfaceDestroyReq),
    @ptrCast(&setImageDescription),
    @ptrCast(&unsetImageDescription),
};

var feedback_impl = [_]?*const anyopaque{
    @ptrCast(&feedbackDestroy),
    @ptrCast(&feedbackGetPreferred),
    @ptrCast(&feedbackGetPreferredParametric),
};

var description_impl = [_]?*const anyopaque{
    @ptrCast(&descriptionDestroy),
    @ptrCast(&descriptionGetInformation),
};

const Params = struct {
    compositor: *Compositor,
    resource: *c.wl_resource,
    tf: ?color.Transfer = null,
    primaries_bt2020: ?bool = null,
    max_cll: u16 = 0,
    max_fall: u16 = 0,
    max_luminance: u16 = 0,
    min_luminance: u16 = 0,
};

fn paramsCreate(_: ?*c.wl_client, resource: ?*c.wl_resource, id: u32) callconv(.c) void {
    const params = userdata(Params, resource orelse return);
    const tf = params.tf orelse {
        c.wl_resource_post_error(
            resource,
            c.WP_IMAGE_DESCRIPTION_CREATOR_PARAMS_V1_ERROR_INCOMPLETE_SET,
            "transfer function is required",
        );
        return;
    };
    const bt2020 = params.primaries_bt2020 orelse {
        c.wl_resource_post_error(
            resource,
            c.WP_IMAGE_DESCRIPTION_CREATOR_PARAMS_V1_ERROR_INCOMPLETE_SET,
            "primaries are required",
        );
        return;
    };
    if (params.max_cll != 0 and params.max_fall > params.max_cll) {
        c.wl_resource_post_error(
            resource,
            c.WP_IMAGE_DESCRIPTION_CREATOR_PARAMS_V1_ERROR_INVALID_LUMINANCE,
            "max_fall exceeds max_cll",
        );
        return;
    }
    sendReady(params.compositor, resource.?, id, .{
        .transfer = tf,
        .bt2020 = bt2020,
        .max_cll = params.max_cll,
        .max_fall = params.max_fall,
        .max_luminance = params.max_luminance,
        .min_luminance = params.min_luminance,
    });
    c.wl_resource_destroy(resource);
}

fn paramsSetTfNamed(_: ?*c.wl_client, resource: ?*c.wl_resource, tf: u32) callconv(.c) void {
    const params = userdata(Params, resource orelse return);
    if (params.tf != null) return alreadySet(resource);
    params.tf = namedTransfer(tf) orelse {
        c.wl_resource_post_error(
            resource,
            c.WP_IMAGE_DESCRIPTION_CREATOR_PARAMS_V1_ERROR_INVALID_TF,
            "unsupported transfer function",
        );
        return;
    };
}

fn paramsSetTfPower(_: ?*c.wl_client, resource: ?*c.wl_resource, _: u32) callconv(.c) void {
    unsupportedParams(resource);
}

fn paramsSetPrimariesNamed(_: ?*c.wl_client, resource: ?*c.wl_resource, primaries: u32) callconv(.c) void {
    const params = userdata(Params, resource orelse return);
    if (params.primaries_bt2020 != null) return alreadySet(resource);
    params.primaries_bt2020 = namedPrimaries(primaries) orelse {
        c.wl_resource_post_error(
            resource,
            c.WP_IMAGE_DESCRIPTION_CREATOR_PARAMS_V1_ERROR_INVALID_PRIMARIES_NAMED,
            "unsupported primaries",
        );
        return;
    };
}

fn paramsSetPrimaries(
    _: ?*c.wl_client,
    resource: ?*c.wl_resource,
    _: i32,
    _: i32,
    _: i32,
    _: i32,
    _: i32,
    _: i32,
    _: i32,
    _: i32,
) callconv(.c) void {
    unsupportedParams(resource);
}

fn paramsSetLuminances(_: ?*c.wl_client, resource: ?*c.wl_resource, _: u32, _: u32, _: u32) callconv(.c) void {
    unsupportedParams(resource);
}

fn paramsSetMasteringPrimaries(
    _: ?*c.wl_client,
    resource: ?*c.wl_resource,
    _: i32,
    _: i32,
    _: i32,
    _: i32,
    _: i32,
    _: i32,
    _: i32,
    _: i32,
) callconv(.c) void {
    unsupportedParams(resource);
}

fn paramsSetMasteringLuminance(_: ?*c.wl_client, resource: ?*c.wl_resource, min_lum: u32, max_lum: u32) callconv(.c) void {
    const params = userdata(Params, resource orelse return);
    if (params.max_luminance != 0 or params.min_luminance != 0) return alreadySet(resource);
    params.min_luminance = clampLuminance(min_lum);
    params.max_luminance = clampLuminance(max_lum);
}

fn paramsSetMaxCll(_: ?*c.wl_client, resource: ?*c.wl_resource, max_cll: u32) callconv(.c) void {
    const params = userdata(Params, resource orelse return);
    if (params.max_cll != 0) return alreadySet(resource);
    params.max_cll = clampLuminance(max_cll);
}

fn paramsSetMaxFall(_: ?*c.wl_client, resource: ?*c.wl_resource, max_fall: u32) callconv(.c) void {
    const params = userdata(Params, resource orelse return);
    if (params.max_fall != 0) return alreadySet(resource);
    params.max_fall = clampLuminance(max_fall);
}

fn namedTransfer(tf: u32) ?color.Transfer {
    return switch (tf) {
        c.WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_ST2084_PQ => .pq,
        c.WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_HLG => .hlg,
        c.WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_EXT_LINEAR => .scrgb,
        c.WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_GAMMA22 => .sdr,
        else => null,
    };
}

fn namedPrimaries(primaries: u32) ?bool {
    return switch (primaries) {
        c.WP_COLOR_MANAGER_V1_PRIMARIES_SRGB => false,
        c.WP_COLOR_MANAGER_V1_PRIMARIES_BT2020 => true,
        else => null,
    };
}

fn clampLuminance(value: u32) u16 {
    return @intCast(@min(value, 65535));
}

fn alreadySet(resource: ?*c.wl_resource) void {
    c.wl_resource_post_error(
        resource,
        c.WP_IMAGE_DESCRIPTION_CREATOR_PARAMS_V1_ERROR_ALREADY_SET,
        "property already set",
    );
}

fn unsupportedParams(resource: ?*c.wl_resource) void {
    c.wl_resource_post_error(
        resource,
        c.WP_IMAGE_DESCRIPTION_CREATOR_PARAMS_V1_ERROR_UNSUPPORTED_FEATURE,
        "parametric request is not advertised",
    );
}

fn destroyParams(resource: ?*c.wl_resource) callconv(.c) void {
    const params = userdata(Params, resource orelse return);
    params.compositor.allocator.destroy(params);
}

var params_impl = [_]?*const anyopaque{
    @ptrCast(&paramsCreate),
    @ptrCast(&paramsSetTfNamed),
    @ptrCast(&paramsSetTfPower),
    @ptrCast(&paramsSetPrimariesNamed),
    @ptrCast(&paramsSetPrimaries),
    @ptrCast(&paramsSetLuminances),
    @ptrCast(&paramsSetMasteringPrimaries),
    @ptrCast(&paramsSetMasteringLuminance),
    @ptrCast(&paramsSetMaxCll),
    @ptrCast(&paramsSetMaxFall),
};

fn sendSupported(resource: *c.wl_resource) void {
    c.wp_color_manager_v1_send_supported_intent(resource, c.WP_COLOR_MANAGER_V1_RENDER_INTENT_PERCEPTUAL);
    c.wp_color_manager_v1_send_supported_feature(resource, c.WP_COLOR_MANAGER_V1_FEATURE_PARAMETRIC);
    c.wp_color_manager_v1_send_supported_feature(resource, c.WP_COLOR_MANAGER_V1_FEATURE_WINDOWS_SCRGB);
    if (c.wl_resource_get_version(resource) >= 3)
        c.wp_color_manager_v1_send_supported_feature(resource, c.WP_COLOR_MANAGER_V1_FEATURE_WINDOWS_BT2100);
    c.wp_color_manager_v1_send_supported_tf_named(resource, c.WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_GAMMA22);
    c.wp_color_manager_v1_send_supported_tf_named(resource, c.WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_ST2084_PQ);
    c.wp_color_manager_v1_send_supported_tf_named(resource, c.WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_HLG);
    c.wp_color_manager_v1_send_supported_tf_named(resource, c.WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_EXT_LINEAR);
    c.wp_color_manager_v1_send_supported_primaries_named(resource, c.WP_COLOR_MANAGER_V1_PRIMARIES_SRGB);
    c.wp_color_manager_v1_send_supported_primaries_named(resource, c.WP_COLOR_MANAGER_V1_PRIMARIES_BT2020);
    c.wp_color_manager_v1_send_done(resource);
}

fn bind(client: ?*c.wl_client, context: ?*anyopaque, version: u32, id: u32) callconv(.c) void {
    const compositor: *Compositor = @ptrCast(@alignCast(context orelse return));
    const resource = c.wl_resource_create(
        client,
        &c.wp_color_manager_v1_interface,
        @intCast(@min(version, VERSION)),
        id,
    ) orelse return c.wl_client_post_no_memory(client);
    c.wl_resource_set_implementation(resource, @ptrCast(&manager_impl), compositor, null);
    sendSupported(resource);
}

pub fn register(compositor: *Compositor) !void {
    _ = try wayland.Global.create(
        compositor.server.getDisplay(),
        &c.wp_color_manager_v1_interface,
        VERSION,
        compositor,
        bind,
    );
    try registerRepresentation(compositor);
}

fn representationDestroy(_: ?*c.wl_client, resource: ?*c.wl_resource) callconv(.c) void {
    c.wl_resource_destroy(resource);
}

fn representationGetSurface(
    _: ?*c.wl_client,
    resource: ?*c.wl_resource,
    id: u32,
    surface_resource: ?*c.wl_resource,
) callconv(.c) void {
    const surface = userdata(SurfaceData, surface_resource orelse return).surface;
    if (surface.color_representation != null) {
        c.wl_resource_post_error(
            resource,
            c.WP_COLOR_REPRESENTATION_MANAGER_V1_ERROR_SURFACE_EXISTS,
            "color representation already exists",
        );
        return;
    }
    const created = c.wl_resource_create(
        c.wl_resource_get_client(resource orelse return),
        &c.wp_color_representation_surface_v1_interface,
        1,
        id,
    ) orelse return c.wl_resource_post_no_memory(resource);
    surface.color_representation = created;
    c.wl_resource_set_implementation(created, @ptrCast(&representation_surface_impl), surface, representationSurfaceDestroy);
}

fn representationSetAlpha(_: ?*c.wl_client, _: ?*c.wl_resource, _: u32) callconv(.c) void {}
fn representationSetCoefficients(_: ?*c.wl_client, _: ?*c.wl_resource, _: u32, _: u32) callconv(.c) void {}
fn representationSetChroma(_: ?*c.wl_client, _: ?*c.wl_resource, _: u32) callconv(.c) void {}

fn representationSurfaceDestroy(resource: ?*c.wl_resource) callconv(.c) void {
    const surface: *Surface = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
    surface.color_representation = null;
}

var representation_manager_impl = [_]?*const anyopaque{
    @ptrCast(&representationDestroy),
    @ptrCast(&representationGetSurface),
};

var representation_surface_impl = [_]?*const anyopaque{
    @ptrCast(&representationDestroy),
    @ptrCast(&representationSetAlpha),
    @ptrCast(&representationSetCoefficients),
    @ptrCast(&representationSetChroma),
};

fn bindRepresentation(client: ?*c.wl_client, context: ?*anyopaque, version: u32, id: u32) callconv(.c) void {
    const compositor: *Compositor = @ptrCast(@alignCast(context orelse return));
    const resource = c.wl_resource_create(
        client,
        &c.wp_color_representation_manager_v1_interface,
        @intCast(@min(version, 1)),
        id,
    ) orelse return c.wl_client_post_no_memory(client);
    c.wl_resource_set_implementation(resource, @ptrCast(&representation_manager_impl), compositor, null);
    c.wp_color_representation_manager_v1_send_supported_alpha_mode(
        resource,
        c.WP_COLOR_REPRESENTATION_SURFACE_V1_ALPHA_MODE_PREMULTIPLIED_ELECTRICAL,
    );
    c.wp_color_representation_manager_v1_send_supported_coefficients_and_ranges(
        resource,
        c.WP_COLOR_REPRESENTATION_SURFACE_V1_COEFFICIENTS_IDENTITY,
        c.WP_COLOR_REPRESENTATION_SURFACE_V1_RANGE_FULL,
    );
    c.wp_color_representation_manager_v1_send_supported_coefficients_and_ranges(
        resource,
        c.WP_COLOR_REPRESENTATION_SURFACE_V1_COEFFICIENTS_BT2020,
        c.WP_COLOR_REPRESENTATION_SURFACE_V1_RANGE_FULL,
    );
    c.wp_color_representation_manager_v1_send_done(resource);
}

fn registerRepresentation(compositor: *Compositor) !void {
    _ = try wayland.Global.create(
        compositor.server.getDisplay(),
        &c.wp_color_representation_manager_v1_interface,
        1,
        compositor,
        bindRepresentation,
    );
}

fn userdata(comptime T: type, resource: *c.wl_resource) *T {
    return @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
}
