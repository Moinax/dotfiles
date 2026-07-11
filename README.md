# Dotfiles

Personal dotfiles for [CachyOS](https://cachyos.org/) (Arch-based) with optional Hyprland or Niri desktop support.

## Features

- **CachyOS-first**: Built for CachyOS; plain Arch and other Arch derivatives work on a best-effort basis (everything installs via pacman/paru)
- **Stock NVIDIA stack**: No driver installation, modprobe options, or kernel parameters are touched — CachyOS's own NVIDIA setup (prebuilt open modules, suspend services) is used as-is
- **KDE base assumed**: Desktop installs expect a KDE Plasma base. Polkit, file manager, and theming packages rely on KDE components already being present.
- **Desktop or terminal mode**: Choose a full desktop setup or a lightweight terminal-only install
- **Interactive installer**: Beautiful TUI prompts using [gum](https://github.com/charmbracelet/gum)
- **Modular packages**: Choose what to install (Hyprland, Niri, Development, Gaming, AI, etc.)
- **Desktop AppImage support**: Installs the FUSE runtime (`fuse2`) for AppImages with a custom import/remove tool via `./manage.sh apps`
- **Chezmoi-powered**: Smart dotfile management with templates and conditional installation
- **Easy to extend**: Add new package groups with simple YAML files

## Quick Start

```bash
# Clone the repository
git clone https://github.com/yourusername/dotfiles.git ~/dotfiles
cd ~/dotfiles

# Run the interactive management menu
./manage.sh

# Or run the installer directly
./manage.sh setup
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
| **Hyprland** | Hyprland compositor with `hypridle`, `hyprlock`, `hyprpaper`, `hyprshot`, `waybar`, `rofi`, `swaync`, `wlogout`, clipboard tooling (`cliphist`, `wl-clipboard`) and Wayland helpers |
| **Niri** | Niri scrollable tiling compositor with Wayland desktop tools (`waybar`, `rofi`, `swaync`, `wlogout`, `sddm`, clipboard, screenshots) |
| **Development** | `neovim`, Cursor, Git tooling (`gh`, `lazygit`, `delta`), containers (`docker`, `docker-compose`, `lazydocker`), build/task tools (`cmake`, `gcc`/`base-devel`, `just`), and Claude Code with [`ccstatusline`](https://github.com/sirmalloc/ccstatusline) |
| **Gaming** | Steam + Discord with performance helpers (`mangohud`, `gamemode`) |
| **Multimedia** | Media and creation tools (`mpv`, `obs-studio`, `ffmpeg`, ImageMagick, GIMP, Inkscape) |
| **Productivity** | File managers (Dolphin + Yazi), thumbnail support (`ffmpegthumbnailer`, `kdegraphics-thumbnailers`), BTRFS snapshots (`snapper`, `snap-pac`/`python3-dnf-plugin-snapper`, `grub-btrfs`), communication/browser apps (Slack, Chrome), archive tools, and themes/icons |
| **AI** | AI-powered desktop tools: `hyprvoice` speech-to-text dictation with local Whisper models |

## Structure

```
dotfiles/
├── manage.sh                # Management script (single entry point)
├── tools/
│   ├── setup.sh             # Bootstrap script (installs gum + git, runs installer)
│   └── manage-cursor-extensions.sh # Export/install Cursor extensions list
├── install/
│   ├── installer.sh         # Main interactive installer
│   ├── distros/
│   │   └── arch.sh          # pacman/paru package functions
│   └── lib/
│       ├── common.sh        # Shared utilities
│       ├── detect.sh        # Distro detection (CachyOS/Arch family)
│       ├── services.sh      # Service management
│       └── tree_select.py   # Interactive package selector TUI
├── packages/
│   ├── common.yaml          # Tools installed via curl/git (zoxide, fnm, etc.)
│   ├── arch/
│   │   └── base.yaml        # Base packages (pacman + AUR)
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

This repo includes a Cursor extensions manager to keep extensions reproducible across machines.

It reads/writes the extension list at `home/dot_config/Cursor/extensions.txt`.

### Usage

```bash
# Interactive menu
./manage.sh cursor

# Export currently installed extensions to extensions.txt
./manage.sh cursor export

# Install all extensions from extensions.txt
./manage.sh cursor install
```

### Notes

- Requires the `cursor` CLI in your `PATH`.
- `install` is idempotent: already-installed extensions are skipped/reinstalled safely.

## External Apps Helper

This repo includes an external apps helper for:

- importing an AppImage into your desktop launcher
- installing a local `.deb`, `.rpm`, or `.pkg.tar.*` inside a Distrobox container
- exporting the installed app to your host launcher with `distrobox-export`
- updating that Distrobox-managed app later using saved metadata
- guiding these flows interactively from `./manage.sh apps`

### Usage

```bash
# Open the helper from the manager
./manage.sh apps

# Import an AppImage into the desktop launcher
./manage.sh apps import-appimage ~/Downloads/MyApp.AppImage

# Install a package into a Distrobox container and export it to the host launcher
./manage.sh apps install-distrobox --container ubuntu --package ~/Downloads/app.deb

# Update a previously managed Distrobox app
./manage.sh apps update-distrobox --name app --package ~/Downloads/app-new.deb

# List saved Distrobox app metadata
./manage.sh apps list
```

### Notes

- `./manage.sh apps` is a real interactive wizard, not just a help menu.
- The root `Manage external apps` menu item is shown only on desktop installs where Distrobox is installed.
- File picking starts in `~/Downloads` and falls back to `$HOME` if that folder does not exist.
- Distrobox install prefers choosing from existing containers before falling back to manual entry.
- Distrobox update uses saved managed app records instead of asking you to type the app name.
- `install-distrobox` tries to auto-detect the new `.desktop` file after install; if multiple entries are added, pass `--app your.desktop`.
- Managed Distrobox app metadata is stored under `${XDG_STATE_HOME:-~/.local/state}/dotfiles/external-apps/distrobox/`.

## Supported Distributions

This repo targets **CachyOS** exclusively. Any Arch-based distro (`ID_LIKE=arch`)
is detected and mapped to the same pacman/paru install path on a best-effort
basis; non-Arch distros are rejected by the installer.

## Manual Chezmoi Usage

If you previously used GNU Stow, this is the main behavior change to keep in mind:

- **Stow mental model**: repo files are symlinked into `$HOME`, so editing the repo is "live" immediately.
- **Chezmoi mental model**: repo files are the **source state** and your home directory is the **target state**. Changes are applied when you run `chezmoi apply` (or related commands).

### First-time setup

Always run `./manage.sh setup`. The installer is the only supported bootstrap path: it seeds `~/.config/chezmoi/chezmoi.toml` with your group selections and applies the dotfiles. Running `chezmoi init` directly is not supported — the managed configs assume packages and services the installer provisions, so a cold apply would produce broken configs for software that isn't installed.

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
2. **Add SSH key** to GitHub/GitLab (displayed during setup)
3. **Hyprland users**: Press `Super+?` to see keybindings
4. **Niri users**: Log out, choose Niri in your display manager, log back in
5. **Dark/light mode**: Press `Mod+N` to toggle between Catppuccin Mocha and Latte
6. **Plymouth**: Reboot to see the boot splash (if configured during install)

## Included Configurations

- **Shell**: zsh with starship prompt, zoxide, television
- **Terminal**: kitty
- **Editor**: Neovim (AstroNvim-based), Cursor
- **Git**: delta for diffs, lazygit
- **Multiplexer**: Zellij
- **File Manager**: yazi, dolphin
- **Hyprland**: hypridle, hyprlock, hyprpaper, hyprshot, waybar, rofi, swaync, wlogout
- **Niri**: niri with waybar, rofi, swaync, wlogout (scrollable tiling Wayland compositor)
- **AI**: hyprvoice dictation with local Whisper speech recognition
- **Claude Code**: [`ccstatusline`](https://github.com/sirmalloc/ccstatusline) status bar (Catppuccin Powerline theme), WorkTrunk worktree plugin
- **AppImage support**: Desktop installs set up the FUSE runtime for AppImages; terminal installs skip it

## Credits

Hyprland configuration originally inspired by [ml4w](https://www.ml4w.com/) starter kit.

## License

MIT License - see [LICENSE](LICENSE) for details.
