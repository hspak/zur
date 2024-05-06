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
- Zig (0.12)
