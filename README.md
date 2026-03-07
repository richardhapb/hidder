# hidder

`hidder` is a Zig library for reading HID devices, parsing report descriptors, and watching field-level input changes.

`src/main.zig` is only a usage example for one XP-Pen device.

## Library scope

The library provides:

- HID device discovery (`discoverDevices`)
- Basic device filtering helper for XP-Pen (`getXPPenDevice`)
- HID report descriptor parsing (`getDescriptors`)
- Field extraction helpers (`FieldDescriptor.extractRaw`, `FieldDescriptor.extractSigned`)
- A thread-safe event queue (`EventQueue`)
- A background report watcher that emits field change events (`ReportsWatcher`)

## Requirements

- Zig `0.16.0-dev.2676+4e2cec265` or compatible
- `hidapi`

macOS (Homebrew):

```bash
brew install hidapi
```

Linux (Debian/Ubuntu example):

```bash
sudo apt install libhidapi-dev
```

## Build

```bash
zig build
```

## Test

```bash
zig build test
```

## Example app

The example entrypoint is `src/main.zig`.

Run it with:

```bash
zig build run
```

Current example behavior:

- Targets one XP-Pen stylus interface
- Subscribes to selected fields (`tip`, `button1`, `button2`, `pressure`)
- Prints field updates to stdout

## API notes

- `getXPPenDevice` is a convenience helper with hardcoded IDs.
- `ReportsWatcher` currently runs continuously; shutdown is not yet graceful.
- Example field subscriptions are index-based; production code should prefer usage-based selection.

## Future improvements

- Dynamic XP-Pen detection instead of a fixed vendor/product/interface tuple.
- A generic device abstraction to support multiple tablet/HID models with one API.
- Usage-based field selection helpers to avoid descriptor-index coupling.
- Graceful watcher termination via an atomic stop flag.

## Project structure

- `src/root.zig`: library implementation
- `src/main.zig`: example executable
- `build.zig`: build config and `hidapi` linking
- `src/c.h`: C bridge header for `hidapi`
