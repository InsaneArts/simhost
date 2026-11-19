# Changelog

Each release of simhost, newest first. Changes that are not in a release yet are under `## Unreleased`.

## Unreleased

**Screens**
- Each new picture of each panel, straight from the simulator's framebuffer, with how its interface is turned.

**Input**
- Touches with one and two fingers, edge swipes, and hardware buttons, straight to SimulatorKit.
- Typing in any app, through a virtual USB keyboard inside the simulator.
- Slow animations and the memory warning.

**iPhone Duo**
- Set the hinge, and read it back to the degree.
- Which panel is lit, how the device is held, and its buttons.

**The host**
- One process owns a simulator's input. Each client hears every other client's input as it happens.
- The `simhost` command: `tap`, `type`, `key`, `fold`, `watch`, `bench` and `serve`.
