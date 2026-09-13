---
name: 000 Distribution Roadmap
overview: "Index for the Sideswipe desktop-then-OS RFCs. Execute 001, then 002; 003–007 fan out; 008 is last."
todos:
  - id: 81cf9881-2d7c-486c-860a-aae62ae2f649
    content: "Keep 001 on the M2 → M3 critical path (shell socket + sideswipe_shell_v1)"
    status: in_progress
  - id: 68091ca8-7dd7-46be-987c-54c387bd3a8b
    content: "Execute 002 Unified Config Store (amends C1; no UI required)"
    status: pending
  - id: 8a758ef8-35b0-4afb-8b8b-a5654337f976
    content: "Execute 003 App SDK after 002 schema exists"
    status: pending
  - id: ee5c3f4c-3927-419c-84bc-870fe9a958c5
    content: "Execute 004 Orbit Radial Menu after 001 M3 + 002"
    status: pending
  - id: ac325f54-ee50-40f7-becb-8f1c51e25b81
    content: "Execute 005 Lollipop Text Toolbar after 001 M3 + 002"
    status: pending
  - id: 5e5b0d92-d39f-4634-baa7-4baf380c0160
    content: "Execute 006 App Packages after 003 MVP"
    status: pending
  - id: 0cb68171-0eae-4cdc-9874-7bebd478cb5e
    content: "Execute 007 Desktop Bootstrap Installer after 001 M3 prebuilts"
    status: pending
  - id: 4ddf300e-fe44-4d7d-b653-f9c4d0cc8244
    content: "Execute 008 Immutable OS Image last (needs 003 + 006 + 007)"
    status: pending
isProject: true
---

> RFC 000. Status: Draft. Target: sideswipe `master`, Zig 0.16.0. This file is an index, not a requirements document. Each numbered plan below is a self-contained RFC.

## Locked product decisions

- Sideswipe stays a Zig compositor. First-party apps use a Zig declarative SDK only. Foreign Wayland clients still run unmodified. The SDK is never ported to other compositors.
- Desktop first: a GUI bootstrap installer turns an existing Linux box into Sideswipe. An immutable ISO (NixOS or Arch) comes after the shell and SDK exist.
- RFC 001 process model stays: compositor owns gestures, layout, focus, and hits; one privileged shell client on `sideswipe_shell_v1`; fallback ring if the shell dies.

## Sequence

```mermaid
flowchart TB
  rfc001[001 Content-First Shell]
  rfc002[002 Unified Config Store]
  rfc003[003 App SDK]
  rfc004[004 Orbit Radial Menu]
  rfc005[005 Lollipop Text Toolbar]
  rfc006[006 App Packages]
  rfc007[007 Desktop Bootstrap]
  rfc008[008 Immutable OS Image]
  rfc001 --> rfc002
  rfc001 --> rfc004
  rfc001 --> rfc005
  rfc001 --> rfc007
  rfc002 --> rfc003
  rfc002 --> rfc004
  rfc002 --> rfc005
  rfc003 --> rfc006
  rfc003 --> rfc008
  rfc006 --> rfc008
  rfc007 --> rfc008
```

| RFC | Plan | Depends on | Amends 001 |
|---|---|---|---|
| 001 | [001-content-first-design.plan.md](001-content-first-design.plan.md) | — | — |
| 002 | [002-unified-config-store.plan.md](002-unified-config-store.plan.md) | 001 C1 sketch | C1 |
| 003 | [003-app-sdk.plan.md](003-app-sdk.plan.md) | 002 schema | — |
| 004 | [004-orbit-radial-menu.plan.md](004-orbit-radial-menu.plan.md) | 001 M3, 002 | S1, S2 |
| 005 | [005-lollipop-text-toolbar.plan.md](005-lollipop-text-toolbar.plan.md) | 001 M3, 002 | S6 |
| 006 | [006-app-packages.plan.md](006-app-packages.plan.md) | 003 MVP | — |
| 007 | [007-desktop-bootstrap.plan.md](007-desktop-bootstrap.plan.md) | 001 M3 prebuilts | — |
| 008 | [008-immutable-os-image.plan.md](008-immutable-os-image.plan.md) | 003, 006, 007 | — |

004 and 005 may run in parallel after 002. 007 may start as soon as prebuilt compositor artifacts exist. Do not start 008 until the desktop path works.

## What this file does not specify

Requirement IDs, protocols, file checklists, and acceptance live in the child RFCs. Do not add product scope here.
