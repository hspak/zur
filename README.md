# Zur (WIP)
### Aur helper written in Zig written specifically for my wants.

## Design Goals
- Install packages from AUR.
- Update packages from AUR.
    - Review PKGBUILD/install script changes only if necessary.
- All actions are contained in `~/.zur`
- Require as little user input as possible.

## Build
**Dependencies**
- Arch Linux (pacman)
- Zig (0.16.0)
- libalpm

## Validation

Run `zig fmt build.zig build.zig.zon src`, then `zig build test`.
The test step checks formatting and runs the unit, integration, and CLI tests.
