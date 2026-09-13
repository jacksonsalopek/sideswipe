---
name: 004 Orbit Radial Menu
overview: "Port Ventana Orbit onto compositor-owned summon: 4–12 slot rings, multi-ring bindings, launch, and editor. Amends RFC 001 S1/S2."
todos:
  - id: 8a57fdaf-5b56-402b-9a98-83282eea8040
    content: "O1 expand ring_geometry to Orbit metrics and 12-slot cap"
    status: pending
  - id: c797fb21-f7aa-44cf-bcfd-c16a2f3cc93d
    content: "O2 port Orbit.Core ring model + store into ring.toml via 002"
    status: pending
  - id: 98da7322-2c17-4e1c-af57-24f1f27c5af7
    content: "O3 sideswipe_shell_v1 ring events for multi-ring, hub, running arc"
    status: pending
  - id: 46529a9f-6609-4f69-b61d-24a640fd7c67
    content: "O4 launch via desktop files; prefer-switch vs new instance"
    status: pending
  - id: fe173825-2b4d-4662-a54e-54f79bff11b7
    content: "O5 remappable summon chord + hold/double-click styles under [shell]"
    status: pending
  - id: 7a018be9-6af1-4f21-9fde-6d8e95b070db
    content: "O6 ring editor in Settings (003) writing the same ring store"
    status: pending
isProject: true
---

> RFC 004. Status: Draft. Target: sideswipe `master`, Zig 0.16.0. Depends on RFC 001 M3 (`sideswipe_shell_v1`, fallback ring) and RFC 002. Amends S1 and S2. Port source: `/home/jsalopek/dev/ventana/orbit/src/Orbit.Core`.

## Requirements Summary

The radial menu is the primary command surface. Orbit's muscle-memory ring (fixed slots, not MRU) replaces the 001 eight-slice sketch. The compositor still hit-tests and activates; the shell only presents. Summon stays compositor-owned (shell button, flick, I8 `Super+Space`) so we never need `WH_MOUSE_LL`.

### Goals

- Port Orbit.Core geometry, navigation, trigger policy, and ring schema.
- Launch apps/files/folders/URLs/actions from slots.
- Multi-ring + per-`app_id` bindings + optional running-apps arc.
- Editor writes `ring.toml` (or Orbit JSON at the path 002 reserved).

### Non-goals

- Win32 hooks, MSIX, Lemon Squeezy, tray-as-lifecycle.
- Hyprland-style bind tables. One remappable summon chord is a `[shell]` setting.
- Gamepad chord, touch bubble, snooze, fullscreen suppress, exclusions (v2 of this RFC).
- Shell death fallback remains the 001 four-action quad ring (P3).

## Requirements (O) — amends S1, S2

- **O1** Slots auto-size: `max(4, highest occupied)`, cap **12**. Slot 1 at 12 o'clock. Empty slots visible; keyboard skips them. Placeholder quad cap in `ring_geometry.zig` rises from 8 to 12.
- **O2** Hit-testing stays in the compositor (`ring_geometry` shared with the shell). Flick activates the matching top-level slot without drawing (S1).
- **O3** Ring store (Orbit schema v3): items `App | File | Folder | Url | Action`; multiple rings; `mainRingId`; bindings by `app_id` then process name. Persist via 002. Invalid store → compiled default seed (terminal, Settings, files).
- **O4** `sideswipe_shell_v1` grows: ring list, hub step-back, `ring_hover`, running-arc snapshot at summon (handles from the compositor toplevel list). `set_ring` remains the write path; compositor persists.
- **O5** Launch uses `.desktop` / exec, not AUMID. `Launch.PreferSwitching` activates an existing toplevel with the same `app_id` when set. Action items replay a stored chord into the previously focused client only if the compositor performs the replay (no `SendInput` from the shell).
- **O6** Per-`app_id` rings with hub step-back to Main. Ctrl+Tab cycles rings only while the ring is open.
- **O7** Styles: shape `{ring, circles}`, surface `{translucent, solid, none}`, diameter/thickness/hub text. Geometry defaults from Orbit.Core; first-run calibration remains optional (001).
- **O8** One remappable summon chord under `[shell]` (default `Super+Space`, already I8). Hold vs toggle and mouse hold vs double-click port `MouseTriggerStateMachine`. This is not a general keybind system.
- **O9** Editor is Settings pages (003). Until 003 exists, a privileged shell surface may edit the same store.

## Approach

```mermaid
flowchart LR
  Input[shell button / flick / chord] --> Comp[compositor hit-test]
  Comp --> Open[ring_open]
  Open --> Shell[shell render]
  Store[ring.toml] --> Comp
  Editor[Settings editor] --> Store
  Comp --> Launch[desktop exec / focus]
```

Port, do not rewrite from memory:

- `Geometry/RingGeometry.cs`, `RingNavigation.cs` → `src/compositor/ring_geometry.zig` + shell draw
- `Models/RingItem.cs`, `Services/JsonRingStore.cs`, `RingBindingResolver.cs` → `src/core/config/` ring schema
- `Triggers/MouseTriggerStateMachine.cs` → compositor `[shell]` translators
- Launch/running apps: compositor + `.desktop`, not DWM

001 S1 "max 8 slices" and S2 "one configured top-level list" are superseded by O1 and O3. Context-sensitive window actions still occupy exactly one designated sub-ring so top-level muscle memory stays stable (S2 intent preserved).

## Acceptance

- Hold shell button: placeholder ring within one refresh; shell replaces it; release on slot 1 launches the seeded terminal.
- Flick in a slot direction activates without a visible ring.
- Occupied slot 12 is reachable; empty slots draw and are skipped by keyboard digits.
- Editing a slot in Settings (or the interim shell editor) survives restart via the 002 store.
- Killing the shell leaves the 001 fallback ring working.

## File Checklist

| Order | File |
|---|---|
| 1 | `src/compositor/ring_geometry.zig` (12 slots, Orbit metrics) |
| 2 | `src/core/config/ring.zig` + `ring.toml` schema |
| 3 | `protocols/xml/sideswipe-shell-v1.xml` (multi-ring, hub, arc) |
| 4 | `src/shell/` ring view |
| 5 | `src/compositor/` launch + prefer-switch |
| 6 | `src/apps/settings/` ring editor pages (after 003) |

## Security Considerations

- Ring protocol stays on the private socket (P2). Ordinary clients cannot set the ring or see global pointer.
- Action-item key replay is compositor-mediated and must no-op on password fields once 005 sensitive-input exists.

## Open Questions

- Persist as TOML vs Orbit JSON schema v3. Prefer TOML if the mapping is 1:1; keep JSON if versioning is cheaper.
- Running-arc cap (Orbit: 10). Confirm 10 unless strip thumbnail cost says otherwise.

## Notes

- Do not port licensing, MSIX updates, or "close Settings → tray". The compositor session is the lifecycle.
- v2 (not this RFC): gamepad, touch bubble, snooze, fullscreen suppress, excluded processes.
