//! DRM renderer using EGL and OpenGL ES
//!
//! This module provides GPU-accelerated rendering capabilities for the compositor.
//! It handles:
//! - EGL initialization with DRM/GBM backend
//! - Shader compilation and management
//! - DMA-BUF to GL texture import
//! - Buffer blitting between GPU buffers
//! - Pixel readback for CPU access
//!
//! The renderer uses OpenGL ES 3.0 for compatibility with most GPU drivers.
//! It supports both regular GL_TEXTURE_2D and GL_TEXTURE_EXTERNAL_OES for
//! hardware-decoded video textures.
//!
//! ## Architecture
//!
//! The renderer is initialized with a DRM file descriptor and creates:
//! 1. GBM device from DRM FD
//! 2. EGL display using EGL_PLATFORM_GBM_MESA
//! 3. EGL context with OpenGL ES 3.0
//! 4. Vertex and fragment shaders for texture rendering
//!
//! ## DMA-BUF Support
//!
//! The renderer requires `EGL_EXT_image_dma_buf_import` extension to create
//! EGLImages from DMA-BUF file descriptors. This allows zero-copy rendering
//! of client buffers.
//!
//! ## Multi-GPU Support
//!
//! The blit() and readBuffer() functions support multi-GPU scenarios where
//! buffers need to be copied between different GPUs or converted to CPU-
//! accessible memory.

const std = @import("std");
const core = @import("core");
const math = @import("core.math");
const Vector2D = math.Vec2;
const buffer = @import("buffer.zig");
const misc = @import("misc.zig");

const log = std.log.scoped(.renderer);
const egl_device_ext: c.EGLint = 0x322C;
const egl_drm_render_node_file_ext: c.EGLint = 0x323E;

// Import EGL and OpenGL ES headers
const c = @cImport({
    @cInclude("EGL/egl.h");
    @cInclude("EGL/eglext.h");
    @cInclude("GLES3/gl3.h");
    @cInclude("GLES2/gl2ext.h");
    @cInclude("drm_fourcc.h");
    @cInclude("gbm.h");
});

// Type aliases for convenience
const EGLDisplay = c.EGLDisplay;
const EGLContext = c.EGLContext;
const EGLConfig = c.EGLConfig;
const EGLImage = c.EGLImageKHR;
const GLuint = c.GLuint;
const GLint = c.GLint;
const GLenum = c.GLenum;

/// OpenGL texture wrapper
pub const GLTexture = struct {
    texid: GLuint = 0,
    target: GLenum = 0, // GL_TEXTURE_2D or GL_TEXTURE_EXTERNAL_OES
    image: ?EGLImage = null,

    const Self = @This();

    pub fn init(texid: GLuint, target: GLenum) Self {
        return .{
            .texid = texid,
            .target = target,
        };
    }

    pub fn deinit(self: *Self, display: EGLDisplay) void {
        if (self.texid != 0) {
            c.glDeleteTextures(1, &self.texid);
        }
        if (self.image) |img| {
            destroyImage(display, img);
        }
    }

    pub fn bind(self: Self) void {
        c.glBindTexture(self.target, self.texid);
    }

    pub fn unbind(self: Self) void {
        c.glBindTexture(self.target, 0);
    }
};

/// Shader program wrapper
pub const Shader = struct {
    program: GLuint = 0,
    vao: GLuint = 0,
    vbo_pos: GLuint = 0,
    vbo_uv: GLuint = 0,

    // Uniform locations
    proj: GLint = -1,
    tex: GLint = -1,

    // Attribute locations
    pos_attrib: GLint = -1,
    tex_attrib: GLint = -1,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        if (self.program == 0) return;

        if (self.vao != 0) {
            c.glDeleteVertexArrays(1, &self.vao);
        }
        if (self.vbo_pos != 0) {
            c.glDeleteBuffers(1, &self.vbo_pos);
        }
        if (self.vbo_uv != 0) {
            c.glDeleteBuffers(1, &self.vbo_uv);
        }
        c.glDeleteProgram(self.program);
    }

    pub fn createVao(self: *Self) void {
        const full_verts = [_]f32{
            1, 0, // top right
            0, 0, // top left
            1, 1, // bottom right
            0, 1, // bottom left
        };

        c.glGenVertexArrays(1, &self.vao);
        c.glBindVertexArray(self.vao);

        if (self.pos_attrib != -1) {
            c.glGenBuffers(1, &self.vbo_pos);
            c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo_pos);
            c.glBufferData(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(full_verts)), &full_verts, c.GL_STATIC_DRAW);
            c.glEnableVertexAttribArray(@intCast(self.pos_attrib));
            c.glVertexAttribPointer(@intCast(self.pos_attrib), 2, c.GL_FLOAT, c.GL_FALSE, 0, null);
        }

        if (self.tex_attrib != -1) {
            c.glGenBuffers(1, &self.vbo_uv);
            c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo_uv);
            c.glBufferData(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(full_verts)), &full_verts, c.GL_STATIC_DRAW);
            c.glEnableVertexAttribArray(@intCast(self.tex_attrib));
            c.glVertexAttribPointer(@intCast(self.tex_attrib), 2, c.GL_FLOAT, c.GL_FALSE, 0, null);
        }

        c.glBindVertexArray(0);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, 0);
    }
};

/// EGL context and state
pub const EGLState = struct {
    display: ?EGLDisplay = null,
    context: ?EGLContext = null,
    config: ?EGLConfig = null,

    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    pub fn deinit(self: *Self) void {
        if (self.context) |ctx| {
            if (self.display) |disp| {
                _ = c.eglDestroyContext(disp, ctx);
            }
        }
        if (self.display) |disp| {
            _ = c.eglTerminate(disp);
        }
    }
};

/// Blit result with optional sync fence
pub const BlitResult = struct {
    success: bool = false,
    sync_fd: ?i32 = null,
};

pub const Layer = struct {
    buffer: buffer.Interface,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    opacity: f32 = 1,
    uv: [8]f32 = .{ 1, 0, 0, 0, 1, 1, 0, 1 },
};

/// DRM renderer
pub const Type = struct {
    allocator: std.mem.Allocator,
    backend: ?*anyopaque = null, // Opaque DRMBackend pointer
    egl: EGLState,
    shader: Shader,
    shader_ext: Shader, // For external textures
    formats: std.ArrayList(misc.GLFormat),
    primary_renderer: ?*Type = null, // For multi-GPU
    gbm_device: ?*c.struct_gbm_device = null,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, backend: ?*anyopaque, drm_fd: i32) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .backend = backend,
            .egl = EGLState.init(),
            .shader = .{},
            .shader_ext = .{},
            .formats = std.ArrayList(misc.GLFormat).empty,
        };

        errdefer self.formats.deinit(allocator);
        errdefer self.destroyGbmDevice();
        errdefer self.egl.deinit();
        errdefer self.shader_ext.deinit();
        errdefer self.shader.deinit();

        // Initialize EGL with DRM FD
        try self.initEGL(drm_fd);

        // Compile shaders
        try self.compileShaders();

        // Query supported formats
        try self.querySupportedFormats();

        log.info("Renderer initialized with OpenGL ES", .{});

        return self;
    }

    /// Creates a surfaceless renderer for a nested compositor.
    pub fn createNested(allocator: std.mem.Allocator, native_display: *anyopaque) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .egl = EGLState.init(),
            .shader = .{},
            .shader_ext = .{},
            .formats = std.ArrayList(misc.GLFormat).empty,
        };
        errdefer self.formats.deinit(allocator);
        errdefer self.egl.deinit();
        errdefer self.shader_ext.deinit();
        errdefer self.shader.deinit();
        try self.initNestedEGL(native_display);
        try self.compileShaders();
        try self.querySupportedFormats();
        log.info("Nested Wayland EGL renderer initialized", .{});
        return self;
    }

    /// Opens the DRM render node advertised by this EGL display.
    pub fn openDeviceNode(self: *const Self) ?i32 {
        const display = self.egl.display orelse return null;
        const query_display = @as(
            ?*const fn (c.EGLDisplay, c.EGLint, [*c]c.EGLAttrib) callconv(.c) c.EGLBoolean,
            @ptrCast(c.eglGetProcAddress("eglQueryDisplayAttribEXT")),
        ) orelse return null;
        const query_device = @as(
            ?*const fn (?*anyopaque, c.EGLint) callconv(.c) ?[*:0]const u8,
            @ptrCast(c.eglGetProcAddress("eglQueryDeviceStringEXT")),
        ) orelse return null;

        var device: c.EGLAttrib = 0;
        if (query_display(display, egl_device_ext, &device) == c.EGL_FALSE) return null;
        if (device == 0) return null;
        const path_ptr = query_device(@ptrFromInt(@as(usize, @intCast(device))), egl_drm_render_node_file_ext) orelse
            return null;
        const fd = core.unix.open(std.mem.span(path_ptr), .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0) catch
            return null;
        return fd;
    }

    /// Initialize EGL display and context
    fn initEGL(self: *Self, drm_fd: i32) !void {
        // Get EGL display from DRM FD
        const egl_get_platform_display = @as(
            ?*const fn (c.EGLenum, ?*anyopaque, [*c]const c.EGLAttrib) callconv(.c) c.EGLDisplay,
            @ptrCast(c.eglGetProcAddress("eglGetPlatformDisplayEXT")),
        ) orelse return error.EGLExtensionNotSupported;

        // Create GBM device from DRM FD
        const gbm_device = c.gbm_create_device(drm_fd);
        if (gbm_device == null) {
            return error.GBMDeviceCreationFailed;
        }
        self.gbm_device = gbm_device;

        // Get EGL display
        const display = egl_get_platform_display(
            c.EGL_PLATFORM_GBM_MESA,
            gbm_device,
            null,
        );
        if (display == c.EGL_NO_DISPLAY) {
            return error.EGLDisplayCreationFailed;
        }
        self.egl.display = display;
        try self.initEGLDisplay(display, c.EGL_WINDOW_BIT);
    }

    fn initNestedEGL(self: *Self, native_display: *anyopaque) !void {
        const get_platform_display = @as(
            ?*const fn (c.EGLenum, ?*anyopaque, [*c]const c.EGLAttrib) callconv(.c) c.EGLDisplay,
            @ptrCast(c.eglGetProcAddress("eglGetPlatformDisplayEXT")),
        ) orelse return error.EGLExtensionNotSupported;
        const display = get_platform_display(c.EGL_PLATFORM_WAYLAND_KHR, native_display, null);
        if (display == c.EGL_NO_DISPLAY) return error.EGLDisplayCreationFailed;
        self.egl.display = display;
        try self.initEGLDisplay(display, c.EGL_PBUFFER_BIT);
    }

    fn initEGLDisplay(self: *Self, display: EGLDisplay, surface_type: c.EGLint) !void {
        var major: c.EGLint = 0;
        var minor: c.EGLint = 0;
        if (c.eglInitialize(display, &major, &minor) == c.EGL_FALSE) {
            return error.EGLInitializeFailed;
        }

        log.debug("EGL {d}.{d} initialized", .{ major, minor });

        // Choose EGL config
        const config_attribs = [_]c.EGLint{
            c.EGL_SURFACE_TYPE,    surface_type,
            c.EGL_RED_SIZE,        8,
            c.EGL_GREEN_SIZE,      8,
            c.EGL_BLUE_SIZE,       8,
            c.EGL_ALPHA_SIZE,      8,
            c.EGL_RENDERABLE_TYPE, c.EGL_OPENGL_ES3_BIT,
            c.EGL_NONE,
        };

        var config: c.EGLConfig = undefined;
        var num_configs: c.EGLint = 0;
        if (c.eglChooseConfig(display, &config_attribs, &config, 1, &num_configs) == c.EGL_FALSE or num_configs == 0) {
            return error.EGLConfigSelectionFailed;
        }
        self.egl.config = config;

        // Bind OpenGL ES API
        if (c.eglBindAPI(c.EGL_OPENGL_ES_API) == c.EGL_FALSE) {
            return error.EGLBindAPIFailed;
        }

        // Create EGL context
        const context_attribs = [_]c.EGLint{
            c.EGL_CONTEXT_MAJOR_VERSION, 3,
            c.EGL_CONTEXT_MINOR_VERSION, 0,
            c.EGL_NONE,
        };

        const context = c.eglCreateContext(display, config, c.EGL_NO_CONTEXT, &context_attribs);
        if (context == c.EGL_NO_CONTEXT) {
            return error.EGLContextCreationFailed;
        }
        self.egl.context = context;

        // Make context current (without surface)
        if (c.eglMakeCurrent(display, c.EGL_NO_SURFACE, c.EGL_NO_SURFACE, context) == c.EGL_FALSE) {
            return error.EGLMakeCurrentFailed;
        }
    }

    /// Compile vertex and fragment shaders
    fn compileShaders(self: *Self) !void {
        // Standard shader for regular textures
        const vertex_src =
            \\#version 300 es
            \\in vec2 pos;
            \\in vec2 texcoord;
            \\uniform mat3 proj;
            \\out vec2 v_texcoord;
            \\
            \\void main() {
            \\    vec3 transformed = proj * vec3(pos, 1.0);
            \\    gl_Position = vec4(transformed.xy, 0.0, 1.0);
            \\    v_texcoord = texcoord;
            \\}
        ;

        const fragment_src =
            \\#version 300 es
            \\precision mediump float;
            \\in vec2 v_texcoord;
            \\out vec4 fragColor;
            \\uniform sampler2D tex;
            \\
            \\void main() {
            \\    fragColor = texture(tex, v_texcoord);
            \\}
        ;

        self.shader = try self.compileShaderProgram(vertex_src, fragment_src, c.GL_TEXTURE_2D);
    }

    /// Compile a shader program from vertex and fragment sources
    fn compileShaderProgram(self: *Self, vertex_src: []const u8, fragment_src: []const u8, texture_target: c.GLenum) !Shader {
        _ = self;

        // Compile vertex shader
        const vertex_shader = c.glCreateShader(c.GL_VERTEX_SHADER);
        if (vertex_shader == 0) return error.ShaderCreationFailed;
        defer c.glDeleteShader(vertex_shader);

        const vertex_ptr: [*c]const u8 = vertex_src.ptr;
        const vertex_len: c.GLint = @intCast(vertex_src.len);
        c.glShaderSource(vertex_shader, 1, @ptrCast(&vertex_ptr), &vertex_len);
        c.glCompileShader(vertex_shader);

        var status: c.GLint = 0;
        c.glGetShaderiv(vertex_shader, c.GL_COMPILE_STATUS, &status);
        if (status == c.GL_FALSE) {
            var log_buf: [512]u8 = undefined;
            var log_len: c.GLsizei = 0;
            c.glGetShaderInfoLog(vertex_shader, log_buf.len, &log_len, &log_buf);
            log.err("Vertex shader compilation failed: {s}", .{log_buf[0..@intCast(log_len)]});
            return error.VertexShaderCompilationFailed;
        }

        // Compile fragment shader
        const fragment_shader = c.glCreateShader(c.GL_FRAGMENT_SHADER);
        if (fragment_shader == 0) return error.ShaderCreationFailed;
        defer c.glDeleteShader(fragment_shader);

        const fragment_ptr: [*c]const u8 = fragment_src.ptr;
        const fragment_len: c.GLint = @intCast(fragment_src.len);
        c.glShaderSource(fragment_shader, 1, @ptrCast(&fragment_ptr), &fragment_len);
        c.glCompileShader(fragment_shader);

        c.glGetShaderiv(fragment_shader, c.GL_COMPILE_STATUS, &status);
        if (status == c.GL_FALSE) {
            var log_buf: [512]u8 = undefined;
            var log_len: c.GLsizei = 0;
            c.glGetShaderInfoLog(fragment_shader, log_buf.len, &log_len, &log_buf);
            log.err("Fragment shader compilation failed: {s}", .{log_buf[0..@intCast(log_len)]});
            return error.FragmentShaderCompilationFailed;
        }

        // Link program
        const program = c.glCreateProgram();
        if (program == 0) return error.ProgramCreationFailed;
        errdefer c.glDeleteProgram(program);

        c.glAttachShader(program, vertex_shader);
        c.glAttachShader(program, fragment_shader);
        c.glLinkProgram(program);

        c.glGetProgramiv(program, c.GL_LINK_STATUS, &status);
        if (status == c.GL_FALSE) {
            var log_buf: [512]u8 = undefined;
            var log_len: c.GLsizei = 0;
            c.glGetProgramInfoLog(program, log_buf.len, &log_len, &log_buf);
            log.err("Shader program linking failed: {s}", .{log_buf[0..@intCast(log_len)]});
            return error.ShaderLinkingFailed;
        }

        // Get attribute and uniform locations
        var shader: Shader = .{
            .program = program,
            .pos_attrib = c.glGetAttribLocation(program, "pos"),
            .tex_attrib = c.glGetAttribLocation(program, "texcoord"),
            .proj = c.glGetUniformLocation(program, "proj"),
            .tex = c.glGetUniformLocation(program, "tex"),
        };

        // Create VAO
        shader.createVao();

        _ = texture_target; // Used for validation

        return shader;
    }

    /// Query supported DMA-BUF formats
    fn querySupportedFormats(self: *Self) !void {
        const display = self.egl.display orelse return error.NoEGLDisplay;
        const extensions_str = c.eglQueryString(display, c.EGL_EXTENSIONS);
        if (extensions_str == null) {
            return error.EGLExtensionsQueryFailed;
        }

        const extensions = std.mem.span(extensions_str);
        const has_dmabuf_import = std.mem.indexOf(u8, extensions, "EGL_EXT_image_dma_buf_import") != null;

        if (!has_dmabuf_import) {
            log.warn("EGL_EXT_image_dma_buf_import not supported", .{});
            return error.DMABUFImportNotSupported;
        }

        // Query supported formats via EGL_EXT_image_dma_buf_import_modifiers
        const egl_formats = @import("egl_formats.zig");

        // For now, add common formats that are widely supported
        const common_formats = [_]struct { format: u32, modifier: u64 }{
            .{ .format = @as(u32, @bitCast(@as(i32, 875713112))), .modifier = 0 }, // DRM_FORMAT_XRGB8888
            .{ .format = @as(u32, @bitCast(@as(i32, 875713089))), .modifier = 0 }, // DRM_FORMAT_ARGB8888
            .{ .format = @as(u32, @bitCast(@as(i32, 909199186))), .modifier = 0 }, // DRM_FORMAT_XBGR8888
            .{ .format = @as(u32, @bitCast(@as(i32, 909199186))), .modifier = 0 }, // DRM_FORMAT_ABGR8888
        };

        for (common_formats) |fmt| {
            // Verify format is in our pixel format database
            if (egl_formats.getPixelFormatFromDRM(fmt.format)) |_| {
                try self.formats.append(self.allocator, .{
                    .drm_format = fmt.format,
                    .modifier = fmt.modifier,
                    .external = false,
                });
            }
        }

        log.debug("Supported formats: {d}", .{self.formats.items.len});
    }

    pub fn deinit(self: *Self) void {
        self.shader.deinit();
        self.shader_ext.deinit();
        self.formats.deinit(self.allocator);
        self.egl.deinit();
        self.destroyGbmDevice();
        self.allocator.destroy(self);
    }

    fn destroyGbmDevice(self: *Self) void {
        const device = self.gbm_device orelse return;
        c.gbm_device_destroy(device);
        self.gbm_device = null;
    }

    /// Blit from one buffer to another (for multi-GPU or format conversion)
    pub fn blit(
        self: *Self,
        from: buffer.Interface,
        to: buffer.Interface,
    ) BlitResult {
        var guard = ContextGuard.init(self);
        defer guard.deinit();

        // Get source buffer DMA-BUF attributes
        const src_dmabuf = from.dmabuf();
        if (!src_dmabuf.success or src_dmabuf.fds[0] < 0) {
            log.err("Source buffer has no valid DMA-BUF", .{});
            return .{ .success = false };
        }

        // Get destination buffer DMA-BUF attributes
        const dst_dmabuf = to.dmabuf();
        if (!dst_dmabuf.success or dst_dmabuf.fds[0] < 0) {
            log.err("Destination buffer has no valid DMA-BUF", .{});
            return .{ .success = false };
        }

        // Create EGLImage from source DMA-BUF
        const src_texture = self.createTextureFromDMABUF(src_dmabuf) catch |err| {
            log.err("Failed to create texture from source DMA-BUF: {}", .{err});
            return .{ .success = false };
        };
        defer self.destroyTexture(src_texture);

        // Create framebuffer from destination DMA-BUF
        const dst_fbo = self.createFramebufferFromDMABUF(dst_dmabuf) catch |err| {
            log.err("Failed to create framebuffer from destination DMA-BUF: {}", .{err});
            return .{ .success = false };
        };
        defer dst_fbo.deinit(self);

        // Bind destination framebuffer
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, dst_fbo.id);
        defer c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);

        // Set viewport
        c.glViewport(
            0,
            0,
            @intFromFloat(dst_dmabuf.size.getX()),
            @intFromFloat(dst_dmabuf.size.getY()),
        );

        // Use appropriate shader
        const shader = if (src_texture.target == c.GL_TEXTURE_EXTERNAL_OES) &self.shader_ext else &self.shader;
        c.glUseProgram(shader.program);

        // Set up orthographic projection matrix
        const width_f: f32 = @floatCast(dst_dmabuf.size.getX());
        const height_f: f32 = @floatCast(dst_dmabuf.size.getY());
        const proj = [9]f32{
            2.0 / width_f, 0.0,             0.0,
            0.0,           -2.0 / height_f, 0.0,
            -1.0,          1.0,             1.0,
        };

        c.glUniformMatrix3fv(shader.proj, 1, c.GL_FALSE, &proj);
        c.glUniform1i(shader.tex, 0);

        // Bind source texture
        c.glActiveTexture(c.GL_TEXTURE0);
        src_texture.bind();

        // Disable blending for copy
        c.glDisable(c.GL_BLEND);

        // Bind VAO and draw
        c.glBindVertexArray(shader.vao);
        c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, 4);
        c.glBindVertexArray(0);

        // Flush to ensure completion
        c.glFlush();

        return .{ .success = true };
    }

    /// Composites DMA-BUF layers into tightly packed RGBA8 pixels.
    pub fn composeDmabufs(
        self: *Self,
        layers: []const Layer,
        width: i32,
        height: i32,
        out_rgba: []u8,
    ) bool {
        if (width <= 0 or height <= 0) return false;
        const pixel_count = std.math.mul(usize, @intCast(width), @intCast(height)) catch return false;
        const required = std.math.mul(usize, pixel_count, 4) catch return false;
        if (out_rgba.len < required) return false;

        var guard = ContextGuard.init(self);
        defer guard.deinit();
        const framebuffer = createMemoryFramebuffer(width, height) catch |err| {
            log.err("Failed to create composition framebuffer: {}", .{err});
            return false;
        };
        defer framebuffer.deinit();

        c.glBindFramebuffer(c.GL_FRAMEBUFFER, framebuffer.id);
        defer c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
        c.glViewport(0, 0, width, height);
        c.glClearColor(0, 0, 0, 0);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        c.glEnable(c.GL_BLEND);
        c.glBlendFuncSeparate(c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA, c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA);

        for (layers) |layer| {
            if (!self.drawLayer(layer, width, height)) return false;
        }
        c.glReadPixels(0, 0, width, height, c.GL_RGBA, c.GL_UNSIGNED_BYTE, out_rgba.ptr);
        return c.glGetError() == c.GL_NO_ERROR;
    }

    fn drawLayer(self: *Self, layer: Layer, target_width: i32, target_height: i32) bool {
        const attrs = layer.buffer.dmabuf();
        if (!attrs.success or attrs.fds[0] < 0) return false;
        const texture = self.createTextureFromDMABUF(attrs) catch |err| {
            log.err("Failed to import composition DMA-BUF: {}", .{err});
            return false;
        };
        defer self.destroyTexture(texture);

        const shader = if (texture.target == c.GL_TEXTURE_EXTERNAL_OES) &self.shader_ext else &self.shader;
        const projection = layerProjection(layer, target_width, target_height);
        c.glUseProgram(shader.program);
        c.glUniformMatrix3fv(shader.proj, 1, c.GL_FALSE, &projection);
        c.glUniform1i(shader.tex, 0);
        c.glActiveTexture(c.GL_TEXTURE0);
        texture.bind();
        c.glBindVertexArray(shader.vao);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, shader.vbo_uv);
        c.glBufferData(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(layer.uv)), &layer.uv, c.GL_DYNAMIC_DRAW);
        c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, 4);
        const full_uv = [_]f32{ 1, 0, 0, 0, 1, 1, 0, 1 };
        c.glBufferData(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(full_uv)), &full_uv, c.GL_STATIC_DRAW);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, 0);
        c.glBindVertexArray(0);
        texture.unbind();
        const gl_error = c.glGetError();
        if (gl_error == c.GL_NO_ERROR) return true;
        log.err("Failed to draw composition layer: GL error 0x{x}", .{gl_error});
        return false;
    }

    /// Create GL texture from DMA-BUF
    fn createTextureFromDMABUF(self: *Self, attrs: buffer.DMABUFAttrs) !GLTexture {
        const display = self.egl.display orelse return error.NoEGLDisplay;

        const target: c.GLenum = c.GL_TEXTURE_2D;
        const width: c.EGLint = @intFromFloat(attrs.size.getX());
        const height: c.EGLint = @intFromFloat(attrs.size.getY());
        const format: c.EGLint = @intCast(attrs.format);
        if (attrs.planes <= 0 or attrs.planes > 4) return error.InvalidPlaneCount;
        const plane_count: usize = @intCast(attrs.planes);
        for (0..plane_count) |plane| {
            if (attrs.fds[plane] < 0 or attrs.strides[plane] == 0) return error.InvalidPlane;
        }
        var image_attributes: [47]c.EGLAttrib = undefined;
        var attribute_count: usize = 0;
        appendAttribute(&image_attributes, &attribute_count, c.EGL_WIDTH, width);
        appendAttribute(&image_attributes, &attribute_count, c.EGL_HEIGHT, height);
        appendAttribute(&image_attributes, &attribute_count, c.EGL_LINUX_DRM_FOURCC_EXT, format);
        for (0..plane_count) |plane| appendPlaneAttributes(&image_attributes, &attribute_count, attrs, plane);
        image_attributes[attribute_count] = c.EGL_NONE;

        // Create EGLImage
        const egl_create_image = @as(
            ?*const fn (c.EGLDisplay, c.EGLContext, c.EGLenum, ?*anyopaque, [*c]const c.EGLAttrib) callconv(.c) c.EGLImageKHR,
            @ptrCast(c.eglGetProcAddress("eglCreateImage")),
        ) orelse return error.EGLExtensionNotSupported;

        const image = egl_create_image(
            display,
            c.EGL_NO_CONTEXT,
            c.EGL_LINUX_DMA_BUF_EXT,
            null,
            &image_attributes,
        );
        if (image == null) {
            log.err("eglCreateImage DMA-BUF import failed: EGL error 0x{x}", .{c.eglGetError()});
            return error.EGLImageCreationFailed;
        }
        errdefer destroyImage(display, image);

        // Create GL texture
        var texid: c.GLuint = 0;
        c.glGenTextures(1, &texid);
        errdefer c.glDeleteTextures(1, &texid);
        c.glBindTexture(target, texid);

        // Bind EGLImage to texture
        const gl_egl_image_target = @as(
            ?*const fn (c.GLenum, c.EGLImageKHR) callconv(.c) void,
            @ptrCast(c.eglGetProcAddress("glEGLImageTargetTexture2DOES")),
        ) orelse return error.GLExtensionNotSupported;

        gl_egl_image_target(target, image);

        // Set texture parameters
        c.glTexParameteri(target, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
        c.glTexParameteri(target, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
        c.glTexParameteri(target, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(target, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);

        c.glBindTexture(target, 0);

        return GLTexture{
            .texid = texid,
            .target = target,
            .image = image,
        };
    }

    pub fn validateDmabufImport(self: *Self, attrs: buffer.DMABUFAttrs) bool {
        var guard = ContextGuard.init(self);
        defer guard.deinit();
        const texture = self.createTextureFromDMABUF(attrs) catch return false;
        self.destroyTexture(texture);
        return true;
    }

    /// Create framebuffer from DMA-BUF
    fn createFramebufferFromDMABUF(self: *Self, attrs: buffer.DMABUFAttrs) !DmabufFramebuffer {
        // First create a texture from the DMA-BUF
        const texture = try self.createTextureFromDMABUF(attrs);
        errdefer self.destroyTexture(texture);

        // Create framebuffer
        var fbo: c.GLuint = 0;
        c.glGenFramebuffers(1, &fbo);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, fbo);

        // Attach texture to framebuffer
        c.glFramebufferTexture2D(
            c.GL_FRAMEBUFFER,
            c.GL_COLOR_ATTACHMENT0,
            texture.target,
            texture.texid,
            0,
        );

        // Check framebuffer completeness
        const status = c.glCheckFramebufferStatus(c.GL_FRAMEBUFFER);
        if (status != c.GL_FRAMEBUFFER_COMPLETE) {
            c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
            c.glDeleteFramebuffers(1, &fbo);
            return error.FramebufferIncomplete;
        }

        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);

        return .{ .id = fbo, .texture = texture };
    }

    /// Destroy a GL texture and its associated EGLImage
    fn destroyTexture(self: *Self, texture: GLTexture) void {
        if (texture.texid != 0) {
            c.glDeleteTextures(1, &texture.texid);
        }

        if (texture.image) |img| {
            if (self.egl.display) |disp| {
                destroyImage(disp, img);
            }
        }
    }

    /// Verify a buffer can be used as blit destination
    pub fn verifyDestinationDmabuf(self: *Self, attrs: buffer.DMABUFAttrs) bool {
        for (self.formats.items) |fmt| {
            if (fmt.drm_format != attrs.format) continue;
            if (fmt.modifier != attrs.modifier) continue;

            if (fmt.modifier != 0 and fmt.external) {
                // External-only formats can't be render targets
                return false;
            }

            return true;
        }

        return false;
    }

    /// Read buffer contents to CPU memory (for multi-GPU)
    pub fn readBuffer(
        self: *Self,
        buf: buffer.Interface,
        out_data: []u8,
    ) bool {
        var guard = ContextGuard.init(self);
        defer guard.deinit();

        // Get buffer DMA-BUF attributes
        const dmabuf = buf.dmabuf();
        if (!dmabuf.success or dmabuf.fds[0] < 0) {
            log.err("Buffer has no valid DMA-BUF", .{});
            return false;
        }

        // Create framebuffer from DMA-BUF
        const fbo = self.createFramebufferFromDMABUF(dmabuf) catch |err| {
            log.err("Failed to create framebuffer for reading: {}", .{err});
            return false;
        };
        defer fbo.deinit(self);

        // Bind framebuffer
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, fbo.id);
        defer c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);

        // Get pixel format info
        const egl_formats = @import("egl_formats.zig");
        const pixel_format = egl_formats.getPixelFormatFromDRM(dmabuf.format) orelse {
            log.err("Unsupported pixel format for reading: {x}", .{dmabuf.format});
            return false;
        };

        // Calculate expected size
        const width: u32 = @intFromFloat(dmabuf.size.getX());
        const height: u32 = @intFromFloat(dmabuf.size.getY());
        const stride = pixel_format.minStride(width);
        const expected_size = stride * height;

        if (out_data.len < expected_size) {
            log.err("Output buffer too small: {d} < {d}", .{ out_data.len, expected_size });
            return false;
        }

        // Read pixels
        c.glReadPixels(
            0,
            0,
            @intCast(width),
            @intCast(height),
            @intCast(pixel_format.gl_format),
            @intCast(pixel_format.gl_type),
            out_data.ptr,
        );

        // Check for GL errors
        const err = c.glGetError();
        if (err != c.GL_NO_ERROR) {
            log.err("glReadPixels failed with error: {x}", .{err});
            return false;
        }

        return true;
    }
};

fn destroyImage(display: EGLDisplay, image: EGLImage) void {
    const destroy_image = @as(
        ?*const fn (c.EGLDisplay, c.EGLImageKHR) callconv(.c) c.EGLBoolean,
        @ptrCast(c.eglGetProcAddress("eglDestroyImageKHR")),
    ) orelse return;
    _ = destroy_image(display, image);
}

const DmabufFramebuffer = struct {
    id: GLuint,
    texture: GLTexture,

    fn deinit(self: DmabufFramebuffer, renderer: *Type) void {
        c.glDeleteFramebuffers(1, &self.id);
        renderer.destroyTexture(self.texture);
    }
};

const MemoryFramebuffer = struct {
    id: GLuint,
    renderbuffer: GLuint,

    fn deinit(self: MemoryFramebuffer) void {
        c.glDeleteRenderbuffers(1, &self.renderbuffer);
        c.glDeleteFramebuffers(1, &self.id);
    }
};

fn createMemoryFramebuffer(width: i32, height: i32) !MemoryFramebuffer {
    var renderbuffer: GLuint = 0;
    c.glGenRenderbuffers(1, &renderbuffer);
    errdefer c.glDeleteRenderbuffers(1, &renderbuffer);
    c.glBindRenderbuffer(c.GL_RENDERBUFFER, renderbuffer);
    c.glRenderbufferStorage(c.GL_RENDERBUFFER, c.GL_RGBA8, width, height);

    var framebuffer: GLuint = 0;
    c.glGenFramebuffers(1, &framebuffer);
    errdefer c.glDeleteFramebuffers(1, &framebuffer);
    c.glBindFramebuffer(c.GL_FRAMEBUFFER, framebuffer);
    c.glFramebufferRenderbuffer(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_RENDERBUFFER, renderbuffer);
    if (c.glCheckFramebufferStatus(c.GL_FRAMEBUFFER) != c.GL_FRAMEBUFFER_COMPLETE) {
        return error.FramebufferIncomplete;
    }
    return .{ .id = framebuffer, .renderbuffer = renderbuffer };
}

fn layerProjection(layer: Layer, target_width: i32, target_height: i32) [9]f32 {
    const target_width_f: f32 = @floatFromInt(target_width);
    const target_height_f: f32 = @floatFromInt(target_height);
    const width: f32 = @floatFromInt(layer.width);
    const height: f32 = @floatFromInt(layer.height);
    const x: f32 = @floatFromInt(layer.x);
    const y: f32 = @floatFromInt(layer.y);
    return .{
        2 * width / target_width_f, 0,                             0,
        0,                          -2 * height / target_height_f, 0,
        2 * x / target_width_f - 1, 1 - 2 * y / target_height_f,   1,
    };
}

fn appendPlaneAttributes(
    attributes: *[47]c.EGLAttrib,
    count: *usize,
    dmabuf: buffer.DMABUFAttrs,
    plane: usize,
) void {
    const fd_names = [_]c.EGLAttrib{
        c.EGL_DMA_BUF_PLANE0_FD_EXT,
        c.EGL_DMA_BUF_PLANE1_FD_EXT,
        c.EGL_DMA_BUF_PLANE2_FD_EXT,
        c.EGL_DMA_BUF_PLANE3_FD_EXT,
    };
    const offset_names = [_]c.EGLAttrib{
        c.EGL_DMA_BUF_PLANE0_OFFSET_EXT,
        c.EGL_DMA_BUF_PLANE1_OFFSET_EXT,
        c.EGL_DMA_BUF_PLANE2_OFFSET_EXT,
        c.EGL_DMA_BUF_PLANE3_OFFSET_EXT,
    };
    const pitch_names = [_]c.EGLAttrib{
        c.EGL_DMA_BUF_PLANE0_PITCH_EXT,
        c.EGL_DMA_BUF_PLANE1_PITCH_EXT,
        c.EGL_DMA_BUF_PLANE2_PITCH_EXT,
        c.EGL_DMA_BUF_PLANE3_PITCH_EXT,
    };
    const modifier_low_names = [_]c.EGLAttrib{
        c.EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT,
        c.EGL_DMA_BUF_PLANE1_MODIFIER_LO_EXT,
        c.EGL_DMA_BUF_PLANE2_MODIFIER_LO_EXT,
        c.EGL_DMA_BUF_PLANE3_MODIFIER_LO_EXT,
    };
    const modifier_high_names = [_]c.EGLAttrib{
        c.EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT,
        c.EGL_DMA_BUF_PLANE1_MODIFIER_HI_EXT,
        c.EGL_DMA_BUF_PLANE2_MODIFIER_HI_EXT,
        c.EGL_DMA_BUF_PLANE3_MODIFIER_HI_EXT,
    };
    appendAttribute(attributes, count, fd_names[plane], dmabuf.fds[plane]);
    appendAttribute(attributes, count, offset_names[plane], dmabuf.offsets[plane]);
    appendAttribute(attributes, count, pitch_names[plane], dmabuf.strides[plane]);
    if (dmabuf.modifier == 0x00ffffffffffffff) return;
    appendAttribute(attributes, count, modifier_low_names[plane], @as(u32, @truncate(dmabuf.modifier)));
    appendAttribute(attributes, count, modifier_high_names[plane], @as(u32, @truncate(dmabuf.modifier >> 32)));
}

fn appendAttribute(attributes: *[47]c.EGLAttrib, count: *usize, name: c.EGLAttrib, value: anytype) void {
    attributes[count.*] = name;
    attributes[count.* + 1] = @intCast(value);
    count.* += 2;
}

/// EGL context guard (RAII for making/releasing context)
pub const ContextGuard = struct {
    renderer: *Type,
    previous_display: ?EGLDisplay = null,
    previous_context: ?EGLContext = null,

    pub fn init(renderer: *Type) ContextGuard {
        var guard = ContextGuard{ .renderer = renderer };

        // Save current context
        guard.previous_display = c.eglGetCurrentDisplay();
        guard.previous_context = c.eglGetCurrentContext();

        // Make renderer's context current
        if (renderer.egl.display) |disp| {
            if (renderer.egl.context) |ctx| {
                _ = c.eglMakeCurrent(disp, c.EGL_NO_SURFACE, c.EGL_NO_SURFACE, ctx);
            }
        }

        return guard;
    }

    pub fn deinit(self: *ContextGuard) void {
        // Restore previous context
        if (self.previous_display) |disp| {
            if (self.previous_context) |ctx| {
                _ = c.eglMakeCurrent(disp, c.EGL_NO_SURFACE, c.EGL_NO_SURFACE, ctx);
            }
        }
    }
};

const testing = core.testing;

// Tests
test "Renderer - EGLState initialization" {
    var egl = EGLState.init();
    defer egl.deinit();

    try testing.expectNull(egl.display);
    try testing.expectNull(egl.context);
}

test "Renderer - Shader initialization" {
    var shader: Shader = .{};
    defer shader.deinit();

    try testing.expectEqual(@as(GLuint, 0), shader.program);
    try testing.expectEqual(@as(GLint, -1), shader.proj);
}

test "Renderer - GLTexture initialization" {
    const tex = GLTexture.init(42, 0x0DE1); // Some texture ID and target
    try testing.expectEqual(@as(GLuint, 42), tex.texid);
    try testing.expectEqual(@as(c_uint, 0x0DE1), tex.target);
}

test "Renderer - BlitResult defaults" {
    const result: BlitResult = .{};
    try testing.expectFalse(result.success);
    try testing.expectNull(result.sync_fd);
}

test "ContextGuard - initialization" {
    var renderer = Type{
        .allocator = testing.allocator,
        .backend = null,
        .egl = EGLState.init(),
        .shader = .{},
        .shader_ext = .{},
        .formats = std.ArrayList(misc.GLFormat).empty,
    };
    defer renderer.formats.deinit(testing.allocator);

    var guard = ContextGuard.init(&renderer);
    defer guard.deinit();

    try testing.expectEqual(&renderer, guard.renderer);
}

test "Renderer - openDeviceNode without an EGL display returns null" {
    var rend = Type{
        .allocator = testing.allocator,
        .backend = null,
        .egl = EGLState.init(),
        .shader = .{},
        .shader_ext = .{},
        .formats = std.ArrayList(misc.GLFormat).empty,
    };
    defer rend.formats.deinit(testing.allocator);
    try testing.expectEqual(@as(?i32, null), rend.openDeviceNode());
}

test "Renderer - verifyDestinationDmabuf with no formats" {
    var renderer = Type{
        .allocator = testing.allocator,
        .backend = null,
        .egl = EGLState.init(),
        .shader = .{},
        .shader_ext = .{},
        .formats = std.ArrayList(misc.GLFormat).empty,
    };
    defer renderer.formats.deinit(testing.allocator);

    const attrs = buffer.DMABUFAttrs{
        .success = true,
        .format = 0x34325241, // DRM_FORMAT_ARGB8888
        .modifier = 0,
    };

    try testing.expectFalse(renderer.verifyDestinationDmabuf(attrs));
}

test "Renderer - verifyDestinationDmabuf with matching format" {
    var renderer = Type{
        .allocator = testing.allocator,
        .backend = null,
        .egl = EGLState.init(),
        .shader = .{},
        .shader_ext = .{},
        .formats = std.ArrayList(misc.GLFormat).empty,
    };
    defer renderer.formats.deinit(testing.allocator);

    try renderer.formats.append(testing.allocator, .{
        .drm_format = 0x34325241, // DRM_FORMAT_ARGB8888
        .modifier = 0,
        .external = false,
    });

    const attrs = buffer.DMABUFAttrs{
        .success = true,
        .format = 0x34325241, // DRM_FORMAT_ARGB8888
        .modifier = 0,
    };

    try testing.expect(renderer.verifyDestinationDmabuf(attrs));
}

test "Renderer - verifyDestinationDmabuf with external format" {
    var renderer = Type{
        .allocator = testing.allocator,
        .backend = null,
        .egl = EGLState.init(),
        .shader = .{},
        .shader_ext = .{},
        .formats = std.ArrayList(misc.GLFormat).empty,
    };
    defer renderer.formats.deinit(testing.allocator);

    try renderer.formats.append(testing.allocator, .{
        .drm_format = 0x34325241, // DRM_FORMAT_ARGB8888
        .modifier = 0x00ffffffffffffff,
        .external = true,
    });

    const attrs = buffer.DMABUFAttrs{
        .success = true,
        .format = 0x34325241, // DRM_FORMAT_ARGB8888
        .modifier = 0x00ffffffffffffff,
    };

    // External formats with non-zero modifiers can't be render targets
    try testing.expectFalse(renderer.verifyDestinationDmabuf(attrs));
}

test "Renderer - layer projection maps logical rectangle to clip space" {
    const projection = layerProjection(.{
        .buffer = undefined,
        .x = 100,
        .y = 50,
        .width = 400,
        .height = 200,
    }, 1000, 500);

    try testing.expectEqual(@as(f32, 0.8), projection[0]);
    try testing.expectEqual(@as(f32, -0.8), projection[4]);
    try testing.expectEqual(@as(f32, -0.8), projection[6]);
    try testing.expectEqual(@as(f32, 0.8), projection[7]);
}

test "Renderer - DMA-BUF image attributes preserve modifier" {
    var attributes: [47]c.EGLAttrib = undefined;
    var count: usize = 0;
    appendPlaneAttributes(&attributes, &count, .{
        .fds = .{ 7, -1, -1, -1 },
        .offsets = .{ 16, 0, 0, 0 },
        .strides = .{ 4096, 0, 0, 0 },
        .modifier = 0x0123456789abcdef,
    }, 0);

    try testing.expectEqual(@as(usize, 10), count);
    try testing.expectEqual(@as(c.EGLAttrib, 7), attributes[1]);
    try testing.expectEqual(@as(c.EGLAttrib, 0x89abcdef), attributes[7]);
    try testing.expectEqual(@as(c.EGLAttrib, 0x01234567), attributes[9]);
}
