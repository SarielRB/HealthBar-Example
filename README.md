# HealthBar Example

A Rojo project demonstrating a billboard health bar driven by a reusable `Damageable` class and a `HealthGui` controller with smooth lerp + delayed grey-bar animation.

## Layout

- `src/shared/Damageable.lua` — HP/damage/heal/death signals (Roblox-agnostic).
- `src/shared/HealthGui.lua` — Binds a `Damageable` to a `BillboardGui` and animates `CurrentHealth` + `GreyHealth` via `UIGradient` transparency.
- `src/server/Main.server.lua` — Wires `workspace.HealthBar` (a part holding the BillboardGui) to a `Damageable`, then ticks random damage. On death, respawns the entity at full HP.

## BillboardGui structure expected on `workspace.HealthBar`

```
BillboardGui
└── Container
    ├── HealthBar
    │   ├── GreyHealth      (GuiObject; UIGradient auto-added)
    │   └── CurrentHealth   (GuiObject; UIGradient auto-added)
    └── HealthText          (TextLabel)
```

## Running

```bash
aftman install
rojo serve
```

Then connect from the Rojo Studio plugin.
