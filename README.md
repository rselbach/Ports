# Ports

A macOS menubar app that shows listening TCP ports and lets you serve directories via HTTP.

## Features

- View all listening TCP ports in the menubar
- One-click HTTP server for any directory
- Local-only HTTP serving by default, with explicit LAN sharing opt-in
- Runs as a menubar-only app (no dock icon)

## Building

```bash
just build    # debug build
just release  # release build
just dmg      # create signed DMG
```

## Disclaimer

This is a personal project I built for my own use. It's provided as-is, without any support or warranty. Feel free to use it, fork it, or ignore it entirely.

## License

MIT
