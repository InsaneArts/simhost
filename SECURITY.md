# Security

## Report a vulnerability

Do not open a public issue for a security problem. Use **Report a vulnerability** on the [Security tab](https://github.com/InsaneArts/simhost/security) of this repository. Only the maintainer sees the report.

Say what the problem is, how to reproduce it, and which commit of simhost you run.

## Supported versions

simhost has no release yet. Fixes go to the main branch.

## What simhost does on your Mac

- It runs as you, with no extra rights. It never asks for a password.
- It loads Xcode's private simulator frameworks from the active Xcode.
- On first use, it builds a helper with your Xcode's `clang` and keeps it in `~/Library/Caches/simhost`. It runs the helper inside the simulator, where the helper adds a virtual keyboard and, on iPhone Duo, a virtual hinge and buttons. They exist only in that simulator.
- It reads SpringBoard's log inside the simulator, to know which of iPhone Duo's panels is lit.
- The host listens on a Unix socket in your temporary folder. Only your user can open it. Any program that runs as you can.
- simhost does not use the network.
