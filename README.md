# Mini Cider for Omarchy 🎵

A beautiful, native, and highly responsive mini-player widget for [Cider 2](https://cider.sh/) (Apple Music), built specifically for the Omarchy desktop environment.

## ✨ Features
* **Native Omarchy Integration**: Sits cleanly in your top bar and drops down into a sleek, Wayland-friendly floating panel.
* **Smart Artwork & Metadata**: Fetches high-resolution album art with built-in Apple Music CDN fallbacks to prevent missing covers.
* **Synchronized Lyrics**: Real-time lyrics powered by LRCLIB, featuring a buttery-smooth, hardware-accelerated dynamic crossfade effect as lines scroll.
* **Spotlight-style Keyboard Navigation**: Navigate search results, queue songs, and control playback without touching your mouse.
* **Instant Queueing**: Queue tracks locally or from Apple's global catalog with automatic regional routing.

## 🚀 Installation

1. Install the plugin to your Omarchy plugins directory:
   ```bash
   git clone https://github.com/pwn27sbx/omarchy-mini-cider.git ~/.config/omarchy/plugins/pwnsxb.apple-music
   ```
2. Open **Cider 2**, go to Settings > Developer > API, and copy your API Token.
3. Save your token in the plugin directory:
   ```bash
   echo "YOUR_TOKEN_HERE" > ~/.config/omarchy/plugins/pwnsxb.apple-music/cider_token.txt
   ```
4. Enable the plugin via the Omarchy CLI or restart your shell:
   ```bash
   omarchy restart shell
   ```

## ⌨️ Keyboard Shortcuts
- `Up/Down`: Navigate through search results.
- `Enter`: Instantly play the selected track.
- `Space`: Add the selected track to play next.
- `Left/Right`: Skip to Previous/Next track (when search is empty).

---
*Built with ❤️ by pwnsxb & Gabi*
