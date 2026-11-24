# simhost

simhost drives an iOS simulator from your own program. It reads the screens straight from the simulator's framebuffers, sends touches and keys, and folds iPhone Duo. It runs no server and encodes no video.

A touch shows on the screen about three times sooner than through [serve-sim](https://github.com/EvanBacon/serve-sim):

| | serve-sim 0.1.49 | simhost |
|---|---|---|
| Touch to the frame that shows it, median | 16.7 ms | 5.6 ms |
| Touch to the frame that shows it, 90th percentile | 20.5 ms | 7.7 ms |
| Touch to the frame that shows it, slowest | 112 ms | 10 ms |
| Start to the first frame | 4 s | 0.2 s |

Measured on one Mac with Xcode 27.2 and an iOS 27.2 iPhone Duo simulator. [Benchmark](#benchmark) says how.

## What it does

- **Screens.** It reports each new picture of each panel as the simulator draws it. A picture is the simulator's own framebuffer, so reading it costs no copy. It also tells how the interface is turned in each panel.
- **Touches and buttons.** One finger, two fingers, the edge swipes, and the hardware buttons go straight to Xcode's SimulatorKit.
- **Typing.** A helper inside the simulator adds a USB keyboard there, so every app takes the keys. With Xcode 27 this needs no Device Hub window.
- **iPhone Duo.** It sets the hinge and reads it back to the degree, tells which panel is lit, turns the device and presses its buttons.
- **One host for each simulator.** One process owns a simulator's input. Each program that drives the simulator is a client of that host, and hears every other client's input as it happens, every move of a finger included.

## Requirements

- A Mac with Xcode 27, and an iOS 27 simulator runtime

simhost was tested on a Mac with Apple silicon, with Xcode 27.2 and iOS 27.2 simulators of iPhone Duo and iPhone 18 Pro only. It uses private interfaces of Xcode, so an Xcode update can break it.

## Build

```sh
git clone https://github.com/InsaneArts/simhost.git
cd simhost
swift build -c release
```

The command is `.build/release/simhost`.

## The command

Each command takes a simulator's UDID. `xcrun simctl list devices booted` shows the UDIDs. The simulator must be booted.

```sh
simhost tap <udid> 0.5 0.5 [cover|inner]   # x and y from 0 to 1, from the top left
simhost type <udid> "Hello, world"         # into the field that has focus
simhost key <udid> 40                      # a key by HID usage, 40 is return
simhost fold <udid> 130 [300]              # iPhone Duo's hinge, over 300 ms
simhost rotate <udid> 3                    # hold it portrait (1), upside down (2), landscape left (3) or right (4)
simhost press <udid> 12 233                # a hardware button by HID page and usage: volume up
simhost watch <udid>                       # print what every client does, and the device's state
simhost bench <udid> [rounds] [--host]     # time a touch to the frame that shows it
simhost serve <udid>                       # run the host
```

A command that needs the host starts it when none runs. The host stops ten minutes after its last client leaves, and when the simulator shuts down.

## The library

Add the package:

```swift
.package(url: "https://github.com/InsaneArts/simhost.git", branch: "main"),
```

Read the screens, and send input through the host:

```swift
import SimHostKit

let simulator = try Simulator(udid: udid)

// Every new picture of every panel. The surface is the live framebuffer:
// copy what you keep, because the simulator draws the next picture into it.
let screens = try Screens(simulator: simulator) { frame in
    print(frame.panel, frame.orientation)
}

// `launch` starts the host when none runs. A program can also run the host
// itself, with `Host(simulator:).run()`.
let host = try HostClient(udid: udid, name: "my tool", launch: ["/path/to/simhost", "serve", udid]) { message in
    if case .state(let state) = message { print(state) }
}
host.send(.touch(.down, x: 0.5, y: 0.5, screen: .duoCover, edge: 0))
host.send(.touch(.up, x: 0.5, y: 0.5, screen: .duoCover, edge: 0))
host.send(.type("Hello"))
host.send(.fold(degrees: 130, milliseconds: 300))
```

## How it works

- **Xcode's frameworks.** simhost loads CoreSimulator and SimulatorKit from the active Xcode at run time. It never links them, because Xcode moves them between releases.
- **Screens.** `Screens` registers SimulatorKit's screen callbacks on each display of the simulator. A callback can come a moment before the picture is in the framebuffer, so simhost reads the framebuffer's seed and looks again after 1, 1, 2, 4, 8 and 16 ms when it has not changed yet.
- **Touches.** `Touchscreen` sends SimulatorKit's Indigo messages through its HID client, with the target of the panel: the screen of an ordinary device, or iPhone Duo's cover or inner screen.
- **The helper.** On first use, simhost builds a small Objective-C program with your Xcode's `clang`, for the simulator SDK, and keeps it in `~/Library/Caches/simhost`. It starts the helper inside the simulator with `simctl spawn`. The helper adds virtual HID devices there: a USB keyboard, and on iPhone Duo the hinge and the buttons. It reads the hinge's mechanical angle from CoreMotion and reports it.
- **The lit panel.** SimulatorKit keeps both of iPhone Duo's panels powered. SpringBoard logs which panel shows the interface, and the host reads that log with `log stream` inside the simulator.
- **The host.** The host listens on a Unix socket in your temporary folder, `simhost-<UDID>.sock`, that only your user can open. `Wire.swift` defines its messages: each one is a length, a kind and a body, little endian.
- **Two clients at once.** When two clients have a finger down on the same panel, the host sends both fingers as one two-finger touch, so neither cuts the other short.

## Benchmark

`simhost bench` times a touch to the first frame that shows it. It needs the probe app, which turns white while a finger is down:

```sh
Probe/build.sh
xcrun simctl install <udid> Probe/build/Probe.app
xcrun simctl launch <udid> dev.simhost.probe
.build/release/simhost bench <udid> 40          # simhost, straight to SimulatorKit
.build/release/simhost bench <udid> 40 --host   # simhost, through the host
```

`Bench/serve-sim-bench.swift` times serve-sim the same way, over its WebSocket and its video stream:

```sh
swiftc -O Bench/serve-sim-bench.swift -o .build/serve-sim-bench
npx --yes serve-sim@0.1.49 --detach <udid> --port 3150
.build/serve-sim-bench <udid> 3150 40
```

## Limits

- simhost uses private interfaces of Xcode. An Xcode update can break them.
- It types printable ASCII on a US layout only. It has no key for any other character.
- The screens are for programs on the same Mac. simhost does not stream them over a network yet.
- The lit panel comes from a line that SpringBoard logs. An iOS update can change that line.
- Only iPhone Duo and iPhone 18 Pro simulators were tested. Other iPhones use the same code. iPad, Apple Watch and Apple TV were not tested.
- Two clients that touch at the same moment were not tested.

## Credits

The framebuffer callbacks, the Indigo messages and the iPhone Duo services follow [serve-sim](https://github.com/EvanBacon/serve-sim) by Evan Bacon, under the Apache License 2.0. [NOTICE](NOTICE) says which parts.

## License

MIT. See [LICENSE](LICENSE).
