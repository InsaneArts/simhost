# Contributing

Bug reports and pull requests are welcome. For a larger change, open an issue first, so we agree on the idea before you write the code.

## Build and test

You need a Mac with Xcode 27 and an iOS 27 simulator runtime.

```sh
swift build
swift test
```

The tests check the protocol and the reading of SpringBoard's log. They need no simulator.

Most of simhost talks to a booted simulator, so check a change on one. `simhost watch <udid>` prints what the host does. The [Benchmark](README.md#benchmark) section of the README says how to time a touch with the probe app.

## Pull requests

- One change per pull request. One logical change per commit.
- A bug fix comes with a test that fails without the fix, where a test can reach the code.
- Match the code around your change. Do not reformat or refactor what you do not need to touch.
- Comments say why, in plain words. The code says what.
- If the change is one a user sees, add a line to `CHANGELOG.md` under `## Unreleased`.

GitHub runs the tests on each pull request.
