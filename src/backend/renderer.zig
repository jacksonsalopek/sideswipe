//! DRM renderer using EGL and OpenGL ES
//! Handles GPU rendering, buffer blitting, and texture management

const std = @import("std");
const core = @import("core");
const math = @import("core.math");
const Vector2D = math.vector2d.Type;
const buffer = @import("buffer.zig");
const misc = @import("misc.zig");

// Import EGL and OpenGL ES headers
const c = @cImport({
    @cInclude("EGL/egl.h");
    @cInclude("EGL/eglext.h");
    @cInclude("GLES3/gl3.h");
    @cInclude("GLES2/gl2ext.h");
    @cInclude("drm_fourcc.h");
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
            _ = c.eglDestroyImageKHR(display, img);
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

/// DRM renderer
pub const Renderer = struct {
    allocator: std.mem.Allocator,
    backend: ?*anyopaque = null, // Opaque DRMBackend pointer
    egl: EGLState,
    shader: Shader,
    shader_ext: Shader, // For external textures
    formats: std.ArrayList(misc.GLFormat),
    primary_renderer: ?*Renderer = null, // For multi-GPU

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
            .formats = std.ArrayList(misc.GLFormat){},
        };

        _ = drm_fd; // TODO: Use to create EGL display

        // TODO: Initialize EGL
        // TODO: Create shaders
        // TODO: Query supported formats

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.shader.deinit();
        self.shader_ext.deinit();
        self.formats.deinit(self.allocator);
        self.egl.deinit();
        self.allocator.destroy(self);
    }

    /// Blit from one buffer to another (for multi-GPU or format conversion)
    pub fn blit(
        self: *Self,
        from: buffer.Interface,
        to: buffer.Interface,
    ) BlitResult {
        _ = self;
        _ = from;
        _ = to;

        // TODO: Implement EGL/OpenGL blitting
        // 1. Get or create texture for 'from' buffer
        // 2. Get or create framebuffer for 'to' buffer
        // 3. Render texture to framebuffer
        // 4. Return sync fence if needed

        return .{ .success = false };
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
        _ = self;
        _ = buf;
        _ = out_data;

        // TODO: glReadPixels from buffer
        return false;
    }
};

/// EGL context guard (RAII for making/releasing context)
pub const ContextGuard = struct {
    renderer: *Renderer,
    previous_display: ?EGLDisplay = null,
    previous_context: ?EGLContext = null,

    pub fn init(renderer: *Renderer) ContextGuard {
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
    var renderer = Renderer{
        .allocator = testing.allocator,
        .backend = null,
        .egl = EGLState.init(),
        .shader = .{},
        .shader_ext = .{},
        .formats = std.ArrayList(misc.GLFormat){},
    };
    defer renderer.formats.deinit(testing.allocator);

    var guard = ContextGuard.init(&renderer);
    defer guard.deinit();

    try testing.expectEqual(&renderer, guard.renderer);
}
