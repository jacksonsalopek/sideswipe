# Sideswipe Compositor

Core compositor implementation for the Sideswipe Wayland compositor.

## Architecture

The compositor is structured following the Hyprland ecosystem patterns:
- **hyprland** → compositor logic (`src/compositor/`)
- **aquamarine** → backend abstraction (`src/backend/`)
- **hyprutils** → core utilities (`src/core/`)
- **hyprgraphics** → graphics (future)

## Components

### Core Modules

#### `compositor.zig`
Main compositor state and coordination:
- Manages all surfaces and their lifecycle
- Interfaces with backend coordinator
- Provides serial number generation
- Coordinates protocol implementations

#### `surface.zig`
Complete wl_surface implementation:
- **Double-buffered state** (pending vs committed)
- **Buffer management** with attachment tracking
- **Damage tracking** (surface and buffer coordinates)
- **Transform and scale** support
- **Role assignment** (toplevel, popup, subsurface, cursor)
- **Parent/child relationships** for subsurfaces
- **Frame callbacks** for rendering synchronization

### Protocol Implementations

#### `protocols/compositor.zig`
wl_compositor protocol (version 6):
- Surface creation and destruction
- Region creation (stub)
- Buffer attachment
- Damage reporting (surface and buffer)
- Transform and scale settings
- Frame callbacks
- Opaque and input regions

#### `protocols/xdg_shell.zig`
XDG shell protocol (version 5):
- **xdg_wm_base** - Base protocol with ping/pong
- **xdg_surface** - Role assignment and configuration
- **xdg_toplevel** - Desktop windows with:
  - Title and app_id metadata
  - Configure/ack_configure handshake
  - Close events
  - Min/max size constraints
  - Fullscreen/maximize states (prepared)
- **xdg_popup** - Popup windows (stub)

## Integration

### Main Entry Point
`src/main.zig` integrates the compositor:
```zig
// Initialize Wayland server
var server = try wayland.Server.init(allocator, null);

// Initialize compositor
var comp = try compositor.Compositor.init(allocator, &server);

// Register protocol globals
try compositor.protocols.wl_compositor.register(comp);
try compositor.protocols.xdg_shell.register(comp);

// Run event loop
server.run();
```

### Backend Connection
The compositor can attach to a backend coordinator:
```zig
var coord = try backend.Coordinator.create(allocator, &backends, .{});
comp.attachBackend(coord);
```

The Wayland backend (`src/backend/wayland.zig`) enables nested mode:
- Creates XDG toplevel windows in host compositor
- Shares DMA-BUF buffers for zero-copy rendering
- Forwards input events from host

## Current Status

### ✅ Implemented
- [x] Core compositor state management
- [x] Surface lifecycle and double-buffering
- [x] wl_compositor protocol (full)
- [x] xdg_shell protocol (basic)
- [x] XDG toplevel windows
- [x] Damage tracking
- [x] Buffer management
- [x] Transform and scale support

### 🚧 In Progress
- [ ] Frame callback dispatching
- [ ] Region implementation (opaque/input)
- [ ] XDG popup windows
- [ ] Subsurface protocol

### 📋 TODO
- [ ] wl_seat protocol (input)
- [ ] wl_output protocol (displays)
- [ ] wl_data_device (clipboard/DnD)
- [ ] Rendering integration
- [ ] Window management logic
- [ ] Focus management
- [ ] Layer shell protocol
- [ ] Tablet and touch protocols

## Usage

### Running the Compositor

Basic usage:
```bash
./zig-out/bin/sideswipe
```

Verbose mode:
```bash
./zig-out/bin/sideswipe -v
```

### Nested Mode

To run as a window in another compositor:
```bash
# In your existing Wayland session
WAYLAND_DISPLAY=wayland-0 ./zig-out/bin/sideswipe
```

The compositor will:
1. Create a Wayland server socket
2. Register wl_compositor and xdg_wm_base globals
3. Accept client connections
4. Handle surface creation and XDG shell windows

### Testing with Clients

Test with simple clients:
```bash
# Terminal session 1: Start compositor
./zig-out/bin/sideswipe -v

# Terminal session 2: Connect a client
WAYLAND_DISPLAY=wayland-1 weston-terminal
```

## Architecture Notes

### Surface State Machine

Surfaces follow a strict state machine:
1. **Created** - Surface exists but has no role
2. **Role assigned** - Surface gets a role (can only happen once)
3. **Configured** - Surface receives initial configure
4. **Mapped** - Surface has buffer attached and committed
5. **Unmapped** - Surface loses buffer
6. **Destroyed** - Surface is removed

### Double Buffering

All surface state is double-buffered:
- **Pending state** accumulates changes from client requests
- **Commit** applies pending state atomically to current state
- This ensures tear-free updates and consistent state

### Protocol Dispatch

Protocol requests flow through:
1. libwayland parses wire protocol
2. Calls C callback functions
3. Callbacks extract user data and call Zig methods
4. Zig methods update surface/compositor state

## Testing

Run compositor tests:
```bash
zig build test
```

Individual module tests are embedded in source files following Zig conventions.

## References

- [Wayland Protocol](https://wayland.freedesktop.org/docs/html/)
- [XDG Shell Protocol](https://wayland.app/protocols/xdg-shell)
- [Hyprland Source](https://github.com/hyprwm/Hyprland)
- [Aquamarine Backend](https://github.com/hyprwm/aquamarine)
- [wlroots tinywl](https://gitlab.freedesktop.org/wlroots/wlroots/-/tree/master/tinywl)
