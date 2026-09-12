# RFC 0001: Content-First, Pointer-Driven Shell for Sideswipe

| Field | Value |
|---|---|
| Status | Draft (rev 3) |
| Target | sideswipe `master` (Zig 0.16.0) |
| Scope | Window model, input model, shell UI, HiDPI, HDR/color, protocol surface, codebase changes |

## Summary

Sideswipe is a Wayland compositor whose entire user-facing surface is transient and summoned at the pointer. There is no persistent bar, dock, or panel. Windows never overlap; they live on a horizontally scrolling strip of columns per workspace, per output. Navigation copies the gesture vocabulary of mobile operating systems (edge/home-bar swipes, long-press, pull-down shade, edit menu) and maps it onto a mouse, a trackpad, and a touchscreen through one input abstraction. The primary command surface is a radial (pie) menu opened by a single pointer button, with gesture shortcuts that fire without the menu being drawn.

This RFC fixes the requirements, the shell process model, the protocols the compositor must implement, and the concrete changes to the current tree needed to get there.

## Motivation

Persistent chrome spends screen area on information that rarely changes, and it burns OLED panels because the same pixels are lit indefinitely. Free-floating, overlapping windows (the Z axis) force the user to manage occlusion, which is bookkeeping unrelated to the content. Keyboard launchers solve the chrome problem but require typing and appear at a fixed location, so they serve keyboard users and leave pointer users with edge-of-screen targets. Mobile platforms solved all three problems with a stack-and-strip window model, transient overlays, and position-relative gestures; the goal is to make those patterns available on a desktop without regressing the tasks desktops exist for.

## Goals

- No compositor-drawn pixel persists on screen while the user is idle. Every shell element appears on demand and disappears on release or after a timeout.
- No two toplevel windows overlap. Layout is a per-output, per-workspace horizontal strip of columns, each column a vertical stack of one or more tiles.
- Every navigation and command action is reachable with one pointer button plus motion. A keyboard is never required for launching, switching, or window management.
- The same gesture vocabulary works on mouse (button chords), trackpad (multi-finger swipes), and touchscreen (edge and hold gestures).
- Existing Wayland clients (GTK4, Qt6, Chromium, Electron, SDL, winit) run unmodified.
- Latency from pointer-button-down to first frame of the radial menu is under one display refresh period, measured via `wp_presentation` feedback on the overlay surface in nested mode.
- Text and client content stay crisp on HiDPI outputs via fractional scale negotiation, with no blurry downscale-upscale round trips.
- HDR content is never silently clipped: where panel and client both support it the compositor passes HDR through, and SDR content never regresses when HDR is present.
- A small fixed accessibility accelerator set exists but is never required for the pointer-only flows above.

## Non-goals

- X11 support. Xwayland is out of scope for the initial milestones.
- Free-floating window mode, even as an option. Apps that cannot function without it get a per-app override that assigns them a full column, not a floating layer.
- Configuration-file-driven keybind systems in the style of Hyprland or sway. A small fixed set of keyboard accelerators exists for accessibility (I8), but the design is validated without them. Window rules (W7) and ring contents are configurable; keybinds are not.
- A general plugin system for the shell in the first release. The shell is one privileged client with a fixed protocol; extensibility comes later.

## Requirements

Identifiers are stable and referenced from the changes section.

### Window model

- **W1** Each output has an ordered list of workspaces. Each workspace is an ordered list of columns. Each column is an ordered list of tiles. A tile holds exactly one `xdg_toplevel`. Workspaces are per-output; a column moves across outputs only via explicit drag-to-edge past a 250 ms dwell threshold. IPC exposes globally indexed `(output, workspace)` pairs.
- **W2** Columns are laid out left to right at their configured widths on an infinite horizontal strip. The viewport scrolls horizontally to keep the focused column visible. Tiles inside a column split the column's height evenly unless a tile's committed `min_size` forces a different split. Output resize or scale change re-runs layout and sends one `configure` per affected toplevel with the final size.
- **W3** A newly mapped unparented `xdg_toplevel` becomes a new column immediately to the right of the focused column and receives focus. Bursts mapped within one event-loop tick (login storms) are inserted right-to-left in map order so the first-mapped ends up leftmost. Fullscreen, maximized, and minimized requests are mapped per W8, never as floating windows.
- **W4** A newly mapped `xdg_toplevel` with a parent (set via `xdg_toplevel.set_parent`, inferred from `xdg_dialog_v1`, or forced by W7) becomes a **sheet**: it is placed inside the parent's tile, anchored to the bottom edge, and the parent's content area shrinks to make room via a `configure` sequence. A sheet never extends outside its parent tile; content taller than the cap is clipped and the client is expected to scroll internally. Modal sheets (per `xdg_dialog_v1.set_modal`) block pointer and keyboard input to the parent tile only; sibling tiles, popups of other tiles, and shell overlays are unaffected. Multiple sheets on one parent stack bottom-up in map order; closing the parent closes its sheets.
- **W5** `xdg_popup` surfaces (menus, tooltips, comboboxes) render above their parent at the positioner-requested location, constrained to the output via the full `constraint_adjustment` (slide, then flip, then resize) algorithm, and are the only client surfaces permitted to overlap a toplevel. Grab semantics follow `xdg_popup` exactly: the compositor sends `popup_done` on any press outside the popup tree. Opening any shell overlay dismisses all popups first; the shell layer sits above popups while open.
- **W6** Focus history is one stack per seat, global across workspaces and outputs. A **back** action pops the stack and refocuses the previous tile, switching workspace and output and scrolling the viewport as needed. Closing a window removes all its entries. Pointer enter sets hover (drives S7); only click, gesture, or `xdg_activation` sets keyboard focus.
- **W7** A per-app override table (keyed on `app_id`, with optional `title_substring` fallback for clients that set no or ambiguous `app_id`) can force: column width, whether parented dialogs become sheets or columns, and whether the app receives server-side decorations. Overrides live in `~/.config/sideswipe/config.toml` under `[window_rules]`. This is a window-rule table, not a keybind system.
- **W8** `set_maximized` maps to "fill current column"; `unset_maximized` restores the tile's strip geometry. `set_fullscreen` maps to a transient output-covering overlay above the strip; `back` or a second `unset_fullscreen` exits it. `set_minimized` is acknowledged but ignored (the compositor sends `configure` without the minimized state) because there is no dock or taskbar. `set_window_geometry` is honored for sheet sizing and popup anchoring. Client-initiated `move`/`resize`/`show_window_menu` receive no grab; the compositor posts no error but takes no action, since strip position is compositor-owned.
- **W9** Layout inputs are `(workspaces, active viewport size in logical pixels, output scale, column width fractions, per-tile min sizes)`. Layout outputs are integer logical geometries plus per-tile `configure` serials. Re-layout is idempotent and side-effect free.

### Input model

- **I1** The compositor owns a small set of **gesture primitives** independent of device type: `hold`, `flick(direction)`, `drag(direction, progress)`, `release`, `back`, `forward`, `zoom(delta)`. `zoom` is continuous; the layout layer quantizes it to width steps. Each physical device maps its native events to these primitives in a device-specific translator. Translators receive finger counts and edge sources where the hardware provides them.
- **I2** Mouse translator: a configurable **shell button** (default `BTN_SIDE`, fallback `BTN_EXTRA` when absent, configurable to any button except `BTN_MIDDLE`) is reserved. Press-and-hold without motion beyond a 6 px dead zone for 400 ms emits `hold`; press, move past the dead zone, and release within 300 ms emits `flick`; press and sustained motion emits `drag` with progress. The compositor defers delivery of the shell-button press to clients until the gesture disambiguates; if no shell gesture fires, the press is replayed to the focused client with the original timestamp. `BTN_BACK`/`BTN_FORWARD` emit `back`/`forward` only when no shell gesture is in progress. `Ctrl+wheel` emits `zoom` only while the shell button is held or the pointer is over a tile gap; otherwise it passes through to the client. `BTN_MIDDLE` is never reserved, because it carries primary-selection paste.
- **I3** Trackpad translator: three-finger swipes emit `drag`/`flick` with the swipe direction; three-finger tap-and-hold (second tap held 300 ms) emits `hold`; pinch emits `zoom`; two-finger horizontal swipe emits `drag(left|right)` for column switch (no edge requirement; the earlier left-edge requirement is dropped as unreliable on trackpads).
- **I4** Touchscreen translator: swipe from the bottom edge (outer 24 logical px) emits `drag`/`flick` up or sideways; swipe from the top edge (outer 24 px) emits `drag` down; long-press (500 ms, 10 px slop) emits `hold`; swipe from the left edge (outer 24 px) emits `back`; pinch emits `zoom`. Edge swipes are claimed by the compositor; the touch sequence is not delivered to clients once the edge threshold is crossed. Non-edge long-press is delivered to the client as well unless a shell overlay opens, in which case the client sequence is cancelled with `touch_cancel`.
- **I5** The compositor consumes shell-button events per I2 before delivering to clients. All other buttons and keys pass through to the focused client unless a shell overlay is open, in which case the overlay (compositor grab) receives them. While a shell overlay is open, `zwp_pointer_constraints` locks/confines are suspended and `zwp_relative_pointer` streams are paused; they resume on overlay close.
- **I6** Gesture translation runs on the Wayland event loop (single-threaded with the rest of the compositor in M0–M2) and must not block on rendering or client round-trips. No separate input thread exists until profiling proves the need; if one is ever added, it communicates with the event loop over a lock-free single-producer queue and never touches `wl_resource` directly.
- **I7** Direction disambiguation: the first 12 px of motion decide the axis by a 30-degree cone around each cardinal. `drag(up|down)` drives switcher/shade; `drag(left|right)` drives column switch. Once an axis wins, the gesture stays locked to it until release.
- **I8** Fixed accessibility accelerators (non-configurable in v1): `Super+Left/Right` previous/next column, `Super+Up` switcher, `Super+Down` shade, `Super+Space` ring, `Escape` back/close overlay. These mirror the gesture primitives and exist only for accessibility; pointer flows never require them.

### Shell surfaces

- **S1** The **radial menu** opens centered on the current pointer position on `hold`. It has up to eight slices at the top level; each slice is either an action or a sub-ring. Sub-rings open on hover or on drag past the slice. Release over a slice activates it; release over the center or outside the ring cancels. `flick` in a direction activates the matching top-level slice without drawing the ring. Hit-testing lives in the compositor (shared `ring_geometry` module) so a slow shell cannot delay activation; the shell is purely presentational and renders highlight state from `ring_hover` events. To meet the latency goal, the compositor draws a placeholder ring (solid quads) on the first frame after `hold` and the shell replaces it with rich content when ready.
- **S2** The top-level ring is user-configured and stable. Context-sensitive content (window actions for the tile under the pointer) lives in exactly one designated sub-ring so top-level muscle memory is never invalidated. Context is frozen at `ring_open`; pointer motion during the grab does not change it.
- **S3** The **switcher** opens on `drag(up)`: a horizontal card strip of every column in the current workspace, virtualized past 12 cards, with adjacent workspaces reachable by dragging past the strip end with a 150 px overscroll. Thumbnails are internal render-to-texture DMA-BUFs handed to the shell as `wl_buffer`s over the shell protocol; no `ext_image_copy_capture` round trip is on this path.
- **S4** The **shade** opens on `drag(down)`: notifications and the status HUD (clock, battery). It closes on release below a 40% progress threshold or on tap outside. In M5 the compositor bridges to an existing notification daemon over D-Bus rather than hosting `org.freedesktop.Notifications` itself; network, audio, and input-method rows are deferred past M5. Clock and battery (`UPower` client) are the only built-in providers in v1.
- **S5** Adjacent-column switch happens on `drag(left|right)` and `flick(left|right)` per I7, with the viewport following the drag progress, mirroring the mobile home-bar side-swipe.
- **S6** An **edit menu** (the iOS text-selection bar; `UIEditMenuInteraction`) appears when the compositor observes a `zwp_primary_selection_v1` selection change (not `wl_data_device` clipboard, which never triggers it). Placement prefers, in order: the `zwp_text_input_v3` cursor rectangle when available, else the pointer position at selection time, else the focused tile center. It offers copy, paste, and search in v1; app-defined actions are deferred (no protocol exists for them yet).
- **S7** A **tile HUD** shows the title and app icon of a tile for 800 ms on pointer enter, then fades over 200 ms. It never persists. Icons resolve via `app_id` → `.desktop` lookup with a generic fallback glyph.
- **S8** Every shell surface has a maximum lifetime (ring: until release; switcher/shade: until release + 5 s clamp; edit menu: 10 s; HUD: 1 s). Any surface that must stay longer than a few seconds drifts by one device pixel on a slow 60 s cycle. Drift is a render offset only and never affects hit-testing. Drift and wallpaper dimming apply only when the output's `is_oled` flag is set.

### Rendering and panel care

- **R1** The compositor draws nothing on an idle frame except client content and the wallpaper. Damage tracking must be correct enough that an idle desktop submits zero frames. Each output commits exactly one buffer per frame; per-surface passthrough commits are removed when the scene graph lands. `wl_surface.frame` callbacks fire only when the output commits a frame containing their surface.
- **R2** Layer order, bottom to top: wallpaper, toplevels and sheets, popups, shell overlays, cursor. Shell surfaces render with alpha so they can fade in and out without triggering client redraws.
- **R3** An output flag records whether the panel is OLED. Autodetection from EDID/DisplayID is best-effort only (no reliable OLED bit exists in either spec today); the config override is the source of truth. When set, the drift in S8 is enabled and the wallpaper is dimmed after the `ext_idle_notifier_v1` idle interval.

### HiDPI and HDR/color

- **H1** Each output advertises a preferred fractional scale derived from mode + physical size (EDID/DisplayID where available) unless overridden in config. Clients receive `wp_fractional_scale_v1` preferred scale and `wp_viewporter` for buffer cropping; legacy `wl_output.scale` sends `ceil(fractional)`. Integer `wl_surface.set_buffer_scale` continues to work and composes with the fractional scale.
- **H2** Layout runs in logical pixels; the scene composites in physical pixels per output. Each surface's buffer is sampled at the scale of the output(s) it is visible on; a surface spanning outputs with different scales re-renders from the client's highest-scale buffer, never from an upscaled low-scale copy.
- **H3** Shell overlays, the fallback ring, and the cursor are scale-aware: geometry is specified in logical pixels (S1) and rasterized at physical resolution. Cursor uses `wp_cursor_shape_manager_v1` with per-output scale.
- **H4** Per-connector `[output]` config holds `scale` (fractional override) and `hdr` (`auto`/`on`/`off`, default `auto`). Missing entries fall back to auto-detection per H1/H5, never to hardcoded 1.0 except in nested-test outputs.
- **H5** Each output publishes HDR caps from the already-parsed CTA-861 HDR static-metadata + colorimetry blocks (EOTFs, max/frame-avg/min luminance, BT.2020) and DisplayID HDR blocks where present. Caps are exposed to clients as `wp_color_manager_v1` output image descriptions; outputs with no HDR blocks advertise SDR-only.
- **H6** The compositor implements `wp_color_management_v1` (surface + output image descriptions) and `wp_color_representation_v1` (YUV/encoding info). A client attaches an HDR image description to opt a surface into HDR. Fullscreen HDR takes a direct passthrough path: the client buffer is scanned out (or single-quad sampled) unmodified and the compositor commits `HDR_OUTPUT_METADATA` + `Colorspace` connector properties. Mixed SDR/HDR strip content composites inside an SDR container in v1 (HDR surfaces are tone-mapped down with a fixed Reinhard operator, SDR whites are never clipped); full HDR scene composition is the tracked v2 follow-up, not a silent drop.
- **H7** SDR is the safe default. The default output image description is sRGB SDR. HDR output mode engages only when all three hold: the client requested an HDR image description, the output caps (H5) allow it, and `[output] hdr` is not `off` (`auto` means passthrough on fullscreen HDR only; `on` allows HDR container for the whole output).
- **H8** The renderer advertises 10-bit (`DRM_FORMAT_XRGB2101010`, `XBGR2101010`, `ARGB2101010`) and 16-bit float (`ABGR16161616F`) DMA-BUF formats alongside 8-bit, imports them via EGL, and never clamps HDR samples in the passthrough path. SDR blending happens in linear light; there is no fake-HDR upconversion of SDR content.

### Process model

- **P1** Gesture recognition, layout, focus, and the input grab live in the compositor process.
- **P2** The shell UI (ring, switcher, shade, edit menu, HUD) is a single **privileged client** launched by the compositor, speaking a private Wayland protocol (`sideswipe_shell_v1`) over a **private socket** (`$XDG_RUNTIME_DIR/sideswipe-shell-$PID`, mode 0700), not the public `WAYLAND_DISPLAY` socket. The compositor passes the socket path via `SIDESWIPE_SHELL_SOCKET` to the child it spawns, then authenticates the peer with `wl_client_get_credentials` pid equality before allowing `sideswipe_shell_v1` to bind. No token string crosses the connection, so ordinary clients cannot guess their way in. This keeps the shell hackable in any toolkit without giving ordinary clients global pointer position or button grabs.
- **P3** If the shell client dies, the compositor restarts it and remains usable through a minimal in-compositor fallback ring (switch, close, launch terminal) drawn through the same overlay quad path as S1's placeholder, so no second renderer exists.
- **P4** External tooling (launcher integration, scripting) uses the existing IPC socket, not the shell protocol. IPC methods are versioned per `sideswipe_compositor@v1`; breaking changes bump the version.

### Configuration

- **C1** One TOML file at `$XDG_CONFIG_HOME/sideswipe/config.toml`: `[shell]` (shell button, dead zones, timeouts), `[ring]` (top-level slices), `[window_rules]` (W7), `[output]` (per-connector `is_oled`, idle dim interval, fractional `scale` override, `hdr = "auto"|"on"|"off"`). Missing file means compiled defaults; invalid entries log and fall back per-key, never abort startup.

### Accessibility

- **A1** The I8 accelerator set, the shell `activate(slice_id)` request path, and focus-visible highlight on the fallback ring are the v1 accessibility floor. Screen-reader and high-contrast support are explicitly deferred.

## Design

### Layout engine

The layout is a pure function from `(workspace state, viewport size, output scale, column width fractions, per-tile min sizes)` to tile geometries plus `configure` serials. It lives in a new `src/compositor/layout/` module with no Wayland dependencies so it can be unit-tested with fabricated windows. Animation (viewport scroll, column insert/remove, sheet slide) is a separate interpolation layer that feeds target geometries into per-tile springs; clients receive one `configure` per animation with the final size, and the compositor scales the last committed buffer with linear filtering during the transition to avoid resize storms. If a client commits the final-size buffer early, the compositor swaps to it immediately and ends the scale animation for that tile.

Column width is one of `{1/4, 1/3, 1/2, 2/3, 1}` of the viewport by default (1/4 exists for ultrawide), adjustable by `zoom` while a tile is hovered, quantized to the nearest step with 120 units of `zoom` delta per step.

### Sheet semantics for dialogs

Clients that create parented toplevels expect them to float. To keep W4 workable:

- The sheet's target height is the smaller of its desired height and 60% of the parent tile height. Desired height resolves in order: `window_geometry` height from the first commit, else `min_size` height clamped by `max_size`, else half the parent height.
- The sheet receives a `configure` with width equal to the parent tile width and the resolved height. The parent receives a `configure` with its shrunken height in the same layout pass.
- Decorations: the compositor sends `xdg_toplevel_decoration_v1.configure(server_side)` to sheets and draws a grab handle at the top edge. Clients with client-side headerbars (GTK) keep them; the handle is additional chrome, not a replacement.
- If a client sets no parent on what is behaviorally a dialog, it becomes a column per W3. The `xdg_dialog_v1` protocol and the W7 override table are the only reclassification signals; heuristics on window size are explicitly rejected.

### Radial menu geometry

The ring is drawn from a description the compositor sends on `hold`: pointer position in output-logical coordinates, output geometry and scale, the top-level slice list, and the frozen context sub-ring. Geometry and hit-testing live in one shared module (`src/compositor/ring_geometry.zig`) compiled into both the compositor and the shell so drawing and activation can never disagree. Slice hit-testing is angular with a dead-zone radius; the compositor performs it and emits `ring_hover(slice_id)` for the shell to render.

`flick` thresholds ship with defaults (6 px dead zone, 300 ms max press, 12 px axis lock) that work without calibration. An optional first-run tool re-calibrates per device and writes to `[shell]`; skipping it is always valid.

### HiDPI and HDR pipeline

HiDPI: the layout engine outputs logical geometries (W9); the scene graph multiplies by each output's fractional scale (H1) to get physical quads. `wp_viewporter` lets clients commit one high-resolution buffer and have the compositor crop/sample it per output; the compositor never asks a client for a low-scale buffer and upscales it for a high-scale output. Shell overlay surfaces are committed at physical resolution with a `wp_viewport` source/destination pair so the ring stays sharp at 1.5x/2x. The preferred scale defaults to 1.0 below ~140 DPI, 1.5 up to ~200 DPI, 2.0 above, computed from mode + physical size, and is always overridable per connector (H4).

HDR: the `core.display` CTA parser already yields per-output HDR caps; `src/compositor/output.zig` publishes them as `wp_color_manager_v1` output image descriptions (H5). Client HDR surfaces arrive with attached image descriptions (`smpte_st_2084`/HLG EOTF, BT.2020, static metadata type 1). Fullscreen HDR bypasses blending: the scene emits a single quad (or direct scanout where the DRM backend allows) and the atomic commit writes `HDR_OUTPUT_METADATA` + `Colorspace` from the surface description. Windowed/mixed content stays in the SDR container with the fixed Reinhard down-map (H6) so v1 cannot regress SDR. When the last HDR surface on an output unmaps, the compositor restores the SDR output description and clears `HDR_OUTPUT_METADATA` in the same atomic commit. The shell itself is always SDR (sRGB); it never requests an HDR image description.

### Protocols required

Server-side implementations, in addition to what exists today (`wl_compositor` v6, `wl_shm`, `wl_subcompositor` is still missing and required):

| Protocol | Purpose | Requirement |
|---|---|---|
| `wl_subcompositor` | Subsurfaces for video, tooltips-in-client | baseline (GTK/Qt/Chromium need it) |
| `xdg_shell` (complete: popups, positioner, parent, states, window geometry) | Baseline | W3–W5, W8 |
| `xdg_dialog_v1` | Modal/dialog identification | W4 |
| `xdg_decoration_unstable_v1` | Force server-side decorations for sheets | W4 |
| `xdg_output_manager_v1` | Logical output description for clients | W1 |
| `wlr_layer_shell_v1` | Wallpaper only | R1 |
| `ext_session_lock_v1` | Lock screen (the only lock path) | M6 |
| `ext_idle_notifier_v1` | Idle detection for dim (R3) | R3 |
| `zwp_pointer_gestures_v1`, `zwp_pointer_constraints_v1`, `zwp_relative_pointer_v1` | Pass-through to clients that want them; games; suspended during shell grabs per I5 | I5 |
| `wl_touch`, `zwp_tablet_v2` (tool + pad) | Touch and stylus input | I4 |
| `zwp_primary_selection_v1`, `zwp_text_input_v3` | Edit menu triggering and placement | S6 |
| `wp_viewporter`, `wp_fractional_scale_v1`, `wp_presentation` | Client buffer cropping/scale (viewporter), HiDPI scale (fractional), frame timing feedback (presentation) | H1–H2, layout, S1 latency |
| `wp_color_management_v1`, `wp_color_representation_v1` | Output image descriptions (caps), surface image descriptions (HDR opt-in), YUV/encoding info | H5–H7 |
| `wp_tearing_control_v1` | Tearing permitted only on the fullscreen HDR passthrough path (gaming/video) | H6 |
| `wp_cursor_shape_manager_v1` | Server-side cursor shapes, per-output scale | H3, shell polish |
| `xdg_activation_v1` | Focus requests from launchers | W6 |
| `ext_foreign_toplevel_list_v1` | Window enumeration for the shell and IPC | S3, P4 |
| `sideswipe_shell_v1` (private, on the private socket only) | Shell client protocol | P2 |

Deferred past v1: `ext_image_copy_capture_v1` (external screen capture for OBS-style tools; the shell uses the internal thumbnail path, not this), `zwp_input_method_v2` (IME; status row deferred with it). Explicitly not deferred: fractional-scale HiDPI (H1–H4, lands M1/M3) and HDR passthrough with `wp_color_management_v1` (H5–H8, lands M6); only full HDR scene composition is v2 (M7).

### `sideswipe_shell_v1` sketch

All coordinates are output-logical pixels; `output` is the `wl_output` global id. `scale` in `ring_open`/`toplevel_thumbnail` is the output's current fractional scale (H1); the shell rasterizes overlays at `logical * scale` physical pixels. Shell surfaces are always SDR sRGB and never carry HDR image descriptions.

Events from compositor to shell:

- `ring_open(serial, x, y, output, scale, slices)` / `ring_hover(serial, slice_id)` / `ring_close/serial)` where `slices` is an array of `(id:u32, label:string, icon:string, has_subring:bool)`.
- `switcher_open/serial, columns)` / `switcher_progress/serial, progress)` / `switcher_close/serial, selected_column)` where `columns` is an array of `(handle:u32, title:string, app_id:string)`.
- `shade_open/serial)` / `shade_progress/serial, progress)` / `shade_close/serial)`
- `edit_menu_open/serial, x, y, mime_types)` / `edit_menu_close/serial)`
- `tile_enter/handle, title, app_id)` / `tile_leave/handle`
- `toplevel_thumbnail/handle, wl_buffer, width, height, scale)` reusing `linux_dmabuf` buffers; the shell destroys the `wl_buffer` to release. `handle` values are private uints created by `tile_enter` and invalidated by `tile_leave`; unknown handles are a protocol error.
- `toplevel_closed/handle)` for entries that vanish while the switcher is open.

Requests from shell to compositor:

- `set_ring/slices` at startup and whenever the user edits the ring; persisted by the compositor to `[ring]`.
- `activate/serial, slice_id` when the shell wants to activate without a pointer (accessibility path); `serial` must match the last `ring_open`.
- `commit_surface/serial, role, wl_surface` to register each overlay surface (`role` in `{ring, switcher, shade, edit_menu, hud}`). Committing a surface with no matching open `serial` is a protocol error; surfaces are double-buffered and mapped only while their open is live.

## Necessary changes to the current tree

The tree today has a working nested Wayland backend, a GLES 3.0 renderer with DMA-BUF import, `wl_compositor` v6 with double-buffered surface state and damage, a basic `xdg_shell` (toplevel only; `xdg_popup` ignores parent and positioner; states are prepared but not driven), stub `wl_seat`, `wl_output`, and `wl_data_device_manager`, no `wl_subcompositor`, a libinput backend producing `PointerButton`, `PointerMotion`, `PointerAxis`, and `KeyboardKey` events into an `EventQueue` (gesture, touch, tablet, and switch events are dropped; `DeviceType` is a single enum so multi-capability devices such as touchpads are misclassified), a display-info stack (EDID, DisplayID, CTA) with SIMD parsing, and a custom IPC socket protocol. There is no scene graph, no focus, no layout, no input dispatch to clients (compositor `output.zig` commits once per surface instead of once per output frame), no layer for compositor-drawn content, and no gesture events.

### `src/backend/input.zig`, `src/backend/libinput.zig`

- Add `Event` variants for `GestureSwipeBegin/Update/End`, `GesturePinchBegin/Update/End`, `GestureHoldBegin/End`, `TouchDown/Up/Motion/Frame/Cancel`, `TabletTool*`, and `SwitchToggle`. libinput already exposes all of these; the translator currently drops them.
- Replace `DeviceType` single enum with a `Capabilities` bitset (`keyboard, pointer, touch, tablet_tool, tablet_pad, gesture, switch_device`) so translators are chosen per capability (I1), not per device.
- Preserve libinput timestamps on every event; the gesture recognizer depends on them.

### New `src/compositor/input/`

- `gesture.zig`: the device-independent primitive recognizer (I1) with one translator per device class (I2–I4) plus axis locking (I7) and press replay (I2). Pure, allocator-free, unit-testable with synthetic event streams.
- `seat.zig`: real `wl_seat` with pointer, keyboard, and touch objects; enter/leave/motion/button/axis/frame delivery; keyboard focus and keymap upload via `xkbcommon` (new system dependency); the shell-button grab (I5) with constraint suspension.
- `focus.zig`: focus stack per seat (W6) with `xdg_activation` integration.
- `ring_geometry.zig`: shared angular hit-testing used by both compositor and shell (S1).
- Move `protocols/seat.zig` under this directory and finish it.

### `src/compositor/protocols/xdg_shell.zig`

- Implement `xdg_positioner` (all anchor/gravity/constraint-adjustment fields) and `xdg_popup` grab semantics with `popup_done` (W5).
- Honor `set_parent`, `set_title`, `set_app_id`, `set_window_geometry`, `set_min_size`/`set_max_size`, map `set_maximized`/`set_fullscreen`/`set_minimized` per W8, and drive `states` in `configure` from the layout engine (W3, W4).
- Reject client `move`/`resize` grabs (no-op, no error) and document it.
- Add `wl_subcompositor`, `xdg_dialog_v1`, `xdg_decoration_unstable_v1`, `xdg_output_manager_v1`, `ext_idle_notifier_v1`, `xdg_activation_v1` in sibling files.
- Add `wp_fractional_scale_v1` + `wp_viewporter` (H1–H2, M1) and `wp_color_management_v1` + `wp_color_representation_v1` + `wp_tearing_control_v1` (H5–H7, M6) in sibling files. Fractional scale can land without color; color must not land without fractional scale already working.

### New `src/compositor/layout/`

- `strip.zig`: workspace/column/tile data model and the layout function (W1–W3, W9).
- `sheet.zig`: sheet placement rules (W4) with the desired-height resolution order.
- `overrides.zig`: `app_id` + title-substring override table loaded from `config.toml` (W7, C1).
- `anim.zig`: spring interpolation and the scaled-buffer-during-resize policy with early-swap.

### New `src/compositor/scene/`

A minimal scene graph with five layers: wallpaper, toplevels and sheets, popups, shell overlays, cursor. Each node carries logical geometry, physical quads per output (logical × fractional scale, H2), opacity, input region, an optional color image description (H6), and a pixman damage region. This replaces the current direct surface list in `compositor.zig` and the per-surface commit loop in `output.zig` with one composite-then-commit per output frame. The renderer gains a per-frame node walk and an alpha-blended quad path for overlays (R2). Fullscreen HDR nodes take a single-quad passthrough path that skips blending (H6). Idle-frame elision (R1) is implemented here by skipping submission when the union of node damage is empty.

### `src/backend/renderer.zig`

- Add alpha blending and per-quad opacity.
- Add solid-color and rounded-rect quads for the placeholder/fallback ring (S1, P3) and sheet grab handle.
- Add a render-to-texture path so the switcher can be handed toplevel thumbnails as DMA-BUF-backed `wl_buffer`s (S3) with no screencopy round trip.
- Add 10-bit and 16-bit float DMA-BUF formats (H8), linear-light SDR blending, and a no-clamp HDR sampling path for passthrough (H6).
- Use the renderer for nested mode too: composite the scene to one buffer per frame, then attach; remove the passthrough path once the scene lands.

### `src/compositor/output.zig`, `src/core/display/`

- Add an `is_oled` output flag defaulting from config (C1); EDID/DisplayID inference is best-effort only (R3).
- Compute preferred fractional scale per output (H1/H4) and drive `wl_output.scale = ceil(fractional)` plus `wp_fractional_scale_v1` events; remove the hardcoded scale-1 in `protocols/output.zig`.
- Surface per-output HDR caps from the CTA/DisplayID parser as `wp_color_manager_v1` output descriptions (H5); wire the already-discovered `HDR_OUTPUT_METADATA`/`Colorspace`/`GAMMA_LUT`/`CTM` DRM props into the atomic commit (H6–H7), including clearing them when the last HDR surface unmaps.
- Add the `ext_idle_notifier_v1` idle timer and dim policy.

### New `src/shell/` (separate binary)

- The privileged shell client (P2) connecting to `SIDESWIPE_SHELL_SOCKET`, initially in Zig with direct `wl_surface` + DMA-BUF drawing to keep dependencies minimal; a toolkit port is possible later because the protocol is presentational.
- Ring, switcher, shade, edit menu, HUD, each a `wl_surface` registered with `commit_surface`. Imports thumbnail `wl_buffer`s via EGL; falls back to `wl_shm` if import fails. All shell rendering is scale-aware physical-pixel (H3) and SDR-only; the shell never attaches color image descriptions.

### `src/ipc/`

- Keep as the external automation surface (P4) under `sideswipe_compositor@v1`. Add methods for `list_toplevels`, `focus`, `close`, `move_column`, `set_ring`, and a `subscribe` for focus and layout change events so a launcher such as a Vicinae-style tool can integrate without the shell protocol. Socket stays mode 0600 in `$XDG_RUNTIME_DIR`.

### `build.zig`

- Generate server headers and code for every protocol in the table above (currently only `xdg-shell` and `linux-dmabuf`). Resolve protocol XML via `pkg-config wayland-protocols --variable=pkgdatadir` with vendored fallbacks under `protocols/xml/`; stop hard-coding `/usr/share`. Add `wlr-protocols`, `wayland-protocols` stable + staging (including `fractional-scale-v1`, `viewporter`, `presentation-time`, `color-management-v1`, `color-representation-v1`, `tearing-control-v1`), and the private `sideswipe-shell-v1.xml` to the scanner step, emitting both server and client headers.
- Add `xkbcommon` and `pixman-1` (already present) to the compositor link set.
- Add a `shell` executable target and a `zig build run-nested` step that starts the compositor nested with the shell attached, which is the primary development loop.

Example development loop, nushell:

```nu
zig build
with-env { WAYLAND_DISPLAY: "wayland-0" } { ./zig-out/bin/sideswipe -v }
# in another terminal (nested display is printed by sideswipe on startup)
with-env { WAYLAND_DISPLAY: "wayland-1" } { foot }
```

### Compatibility matrix (run per milestone from M1 on)

GTK4 (gnome-text-editor), Qt6 (qtdemo), Chromium, Electron (vscode), SDL (testgles), winit (winit example). Each must map, resize through one animation, open one parented dialog as a sheet, and open one popup. Failures go to the W7 table, never to floating exceptions. From M1 on, the matrix also runs at fractional scales 1.5 and 2.0 (crisp text, correct `wl_output.scale` ceil, H1–H2). From M6 on, it adds an HDR row (mpv or Chromium HDR sample on an HDR-capable output: HDR metadata committed on fullscreen, SDR restored after, H5–H7).

## Security considerations

- The shell protocol binds only on the private socket after pid-equality authentication (P2). It is never advertised on the public socket.
- IPC socket is mode 0600; no network listener exists.
- Thumbnails and global pointer position are visible only to the shell client, never to ordinary clients.
- Session lock (`ext_session_lock_v1`) blanks all outputs and drops input to clients until unlock; it ships in M6 before any real-hardware daily use.
- HDR image descriptions and output caps reveal panel capabilities; they are per-output public info, but per-surface HDR metadata is visible only to the owning client and the compositor, never to other clients.

## Open questions

- Whether modal sheets should also dim the parent tile. Default: dim 20%, configurable under `[window_rules]`; revisit after M4 dogfooding.
- Thumbnail transport starts as DMA-BUF-backed `wl_buffer` with automatic `wl_shm` fallback in the shell; the open question is closed to "both, with fallback" unless integrated-GPU measurement shows the fallback is never hit, in which case it can be removed.
- Full HDR scene composition (M7): which tone-mapping operator and whether the mixed-scene container stays SDR or moves to HDR. v1 ships the fixed Reinhard down-map (H6); the operator choice for true HDR containers stays open and tracked, not dropped.

## Milestones

- **M0** Input dispatch: real `wl_seat`, focus, clients receive pointer and keyboard. Nested mode only. Includes `wl_subcompositor` and xkbcommon keymap.
- **M1** Strip layout with columns, no animation, no sheets. `xdg_popup` complete. `wp_fractional_scale_v1` + `wp_viewporter` with logical-layout/physical-render split (H1–H2, H4 scale override). Compatibility matrix green for map + resize at 1.0/1.5/2.0. DRM smoke test (one output, no atomic) to validate formats/modifiers early and log parsed HDR caps (H5).
- **M2** Gesture recognizer with mouse translator (I2 defaults, no calibration gate); in-compositor fallback ring (scale-aware, H3); adjacent-column switch and back.
- **M3** Shell client with ring and switcher over `sideswipe_shell_v1` on the private socket; internal thumbnails; placeholder-ring latency path measured with `wp_presentation`. Shell rasterizes at physical resolution (H3).
- **M4** Sheets, `xdg_dialog`, override table, animation with early-swap. Renderer gains 10-bit/float format import (H8).
- **M5** Shade (bridged notifications, clock + battery HUD), edit menu, tile HUD, OLED/idle policy.
- **M6** Trackpad and touchscreen translators; full DRM atomic session on real hardware; `wp_color_management_v1` + `wp_color_representation_v1` with fullscreen HDR passthrough and `HDR_OUTPUT_METADATA` commit/clear (H5–H7); session lock; I8 accelerators; accessibility floor (A1). HDR compatibility row green.
- **M7** (v2, tracked) Full HDR scene composition for mixed SDR/HDR strips; operator and container choice per open questions. v1's SDR-container down-map must keep passing while M7 is in flight.
