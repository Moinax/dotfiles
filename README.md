# Dotfiles

Personal dotfiles for Arch Linux, Fedora, and Debian/Ubuntu with optional Hyprland or Niri desktop support.

## Features

- **Multi-distro support**: Works on Arch Linux, Fedora, and Debian/Ubuntu (extensible to other distros)
- **Desktop or terminal mode**: Choose a full desktop setup or a lightweight terminal-only install
- **Interactive installer**: Beautiful TUI prompts using [gum](https://github.com/charmbracelet/gum)
- **Modular packages**: Choose what to install (Hyprland, Niri, Development, Gaming, AI, etc.)
- **Chezmoi-powered**: Smart dotfile management with templates and conditional installation
- **Easy to extend**: Add new distros or package groups with simple YAML files

## Quick Start

```bash
# Clone the repository
git clone https://github.com/yourusername/dotfiles.git ~/dotfiles
cd ~/dotfiles

# Run the installer
./setup.sh
```

The interactive installer will:
1. Detect your distribution
2. Choose setup type (Desktop or Terminal)
3. Let you choose package groups to install
4. Install all selected packages
5. Apply dotfiles using Chezmoi
6. Enable required services
7. Set up SSH keys and shell

## Package Groups

| Group | Description |
|-------|-------------|
| **Hyprland** | Hyprland compositor with `hypridle`, `hyprlock`, `hyprpaper`, `hyprshot`, `waybar`, `rofi`, `mako`, `wlogout`, clipboard tooling (`cliphist`, `wl-clipboard`) and Wayland helpers |
| **Niri** | Niri scrollable tiling compositor with Wayland desktop tools (`waybar`, `rofi`, `mako`, `wlogout`, `sddm`, clipboard, screenshots) |
| **Development** | `neovim`, Cursor, Git tooling (`gh`, `lazygit`, `delta`), containers (`docker`, `docker-compose`, `lazydocker`), and build/task tools (`cmake`, `gcc`/`base-devel`, `just`) |
| **Gaming** | Steam + Discord with performance helpers (`mangohud`, `gamemode`) |
| **Multimedia** | Media and creation tools (`mpv`, `obs-studio`, `ffmpeg`, ImageMagick, GIMP, Inkscape) |
| **Productivity** | File managers (Dolphin + Yazi), thumbnail support (`ffmpegthumbnailer`, `kdegraphics-thumbnailers`), BTRFS snapshots (`snapper`, `snap-pac`/`python3-dnf-plugin-snapper`, `grub-btrfs`), communication/browser apps (Slack, Chrome), archive tools, and themes/icons |
| **AI** | AI-powered desktop tools: `hyprvoice` speech-to-text dictation with local Whisper models |

## Structure

```
dotfiles/
├── setup.sh                 # Bootstrap script (entry point)
├── manage-cursor-extensions.sh # Export/install Cursor extensions list
├── install/
│   ├── installer.sh         # Main interactive installer
│   ├── distros/
│   │   ├── arch.sh          # Arch Linux package functions
│   │   ├── fedora.sh        # Fedora package functions
│   │   └── debian.sh        # Debian/Ubuntu package functions
│   └── lib/
│       ├── common.sh        # Shared utilities
│       ├── detect.sh        # Distro detection
│       ├── services.sh      # Service management
│       └── tree_select.py   # Interactive package selector TUI
├── packages/
│   ├── common.yaml          # Cross-distro tools (zoxide, volta, etc.)
│   ├── arch/
│   │   └── base.yaml        # Arch base packages
│   ├── fedora/
│   │   └── base.yaml        # Fedora base packages
│   ├── debian/
│   │   └── base.yaml        # Debian/Ubuntu base packages
│   └── groups/
│       ├── hyprland.yaml    # Hyprland + Wayland tools
│       ├── niri.yaml        # Niri compositor + Wayland tools
│       ├── development.yaml # Dev tools
│       ├── gaming.yaml      # Gaming packages
│       ├── multimedia.yaml  # Media tools
│       ├── productivity.yaml
│       └── ai.yaml          # AI tools (dictation, Whisper)
├── home/                    # Chezmoi source directory
│   ├── .chezmoiignore       # Conditional dotfile rules
│   ├── dot_config/          # ~/.config files
│   ├── dot_zshrc            # ~/.zshrc
│   └── ...
└── README.md
```

## Cursor Extensions Script

This repo includes `manage-cursor-extensions.sh` to keep Cursor extensions reproducible across machines.

It reads/writes the extension list at `home/dot_config/Cursor/extensions.txt`.

### Usage

```bash
# Interactive menu
./manage-cursor-extensions.sh

# Export currently installed extensions to extensions.txt
./manage-cursor-extensions.sh export

# Install all extensions from extensions.txt
./manage-cursor-extensions.sh install
```

### Notes

- Requires the `cursor` CLI in your `PATH`.
- `install` is idempotent: already-installed extensions are skipped/reinstalled safely.

## Adding a New Distribution

1. Create `install/distros/<distro>.sh` with package manager functions
2. Create `packages/<distro>/base.yaml` with package names
3. Add distro-specific packages to `packages/groups/*.yaml`
4. Update `install/lib/detect.sh` if needed

Three distro families are already supported: Arch, Fedora, and Debian/Ubuntu (see `install/distros/debian.sh` for a real example).

## Manual Chezmoi Usage

If you previously used GNU Stow, this is the main behavior change to keep in mind:

- **Stow mental model**: repo files are symlinked into `$HOME`, so editing the repo is "live" immediately.
- **Chezmoi mental model**: repo files are the **source state** and your home directory is the **target state**. Changes are applied when you run `chezmoi apply` (or related commands).

### First-time setup (manual)

```bash
# Initialize chezmoi with this repo
chezmoi init --source=~/dotfiles/home

# Verify source is correct (important)
chezmoi source-path
```

### Daily commands (most useful)

```bash
# See what would change before touching your home files
chezmoi diff

# Apply source state to your home directory
chezmoi apply

# Edit a managed file safely (writes back to source state)
chezmoi edit ~/.zshrc

# Check what changed in source state
chezmoi status

# Pull and apply latest changes from your remote dotfiles repo
chezmoi update
```

### Typical workflow after editing this repo

```bash
cd ~/dotfiles
git pull
chezmoi diff
chezmoi apply
```

### Can Chezmoi auto-apply?

Yes, but it is not the default behavior.

- **Recommended default**: keep manual `chezmoi diff` + `chezmoi apply` so changes are explicit.
- **Possible auto-apply**: run a file watcher (e.g. `inotifywait`/`entr`) or a user `systemd` path service that triggers `chezmoi apply` when files in `~/dotfiles/home` change.
- **Caveat**: fully automatic apply can surprise you during partial edits; many users prefer explicit applies for safer config management.

## Post-Installation

After running the installer:

1. **Log out and back in** for shell changes to take effect
2. **Start tmux** and press `Ctrl+b I` to install tmux plugins
3. **Add SSH key** to GitHub/GitLab (displayed during setup)
4. **Hyprland users**: Press `Super+?` to see keybindings
5. **Niri users**: Log out, choose Niri in your display manager, log back in
6. **Dark/light mode**: Press `Mod+N` to toggle between Catppuccin Mocha and Latte
7. **Plymouth**: Reboot to see the boot splash (if configured during install)

## Included Configurations

- **Shell**: zsh with starship prompt, zoxide, fzf
- **Terminal**: kitty
- **Editor**: Neovim (AstroNvim-based), Cursor
- **Git**: delta for diffs, lazygit
- **Multiplexer**: tmux with TPM
- **File Manager**: yazi, dolphin
- **Hyprland**: hypridle, hyprlock, hyprpaper, hyprshot, waybar, rofi, mako, wlogout
- **Niri**: niri with waybar, rofi, mako, wlogout (scrollable tiling Wayland compositor)
- **AI**: hyprvoice dictation with local Whisper speech recognition

## Credits

Hyprland configuration originally inspired by [ml4w](https://www.ml4w.com/) starter kit.

## License

MIT License - see [LICENSE](LICENSE) for details.
