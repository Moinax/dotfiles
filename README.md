# Dotfiles

Personal dotfiles for [CachyOS](https://cachyos.org/) (Arch-based) with optional Hyprland desktop support.

## Features

- **CachyOS-first**: Built for CachyOS; plain Arch and other Arch derivatives work on a best-effort basis (everything installs via pacman/paru)
- **Stock NVIDIA stack**: No driver installation, modprobe options, or kernel parameters are touched — CachyOS's own NVIDIA setup (prebuilt open modules, suspend services) is used as-is
- **KDE base assumed**: Desktop installs expect a KDE Plasma base. Polkit, file manager, and theming packages rely on KDE components already being present.
- **Desktop or terminal mode**: Choose a full desktop setup or a lightweight terminal-only install
- **Interactive installer**: Beautiful TUI prompts using [gum](https://github.com/charmbracelet/gum)
- **Modular packages**: Choose what to install (Hyprland, Development, Gaming, AI, etc.)
- **Desktop AppImage support**: Installs the FUSE runtime (`fuse2`) for AppImages with a custom import/remove tool via `dots apps`
- **Chezmoi-powered**: Smart dotfile management with templates and conditional installation
- **Easy to extend**: Add new package groups with simple YAML files

## Quick Start

```bash
# Clone the repository
git clone https://github.com/Moinax/dotfiles.git ~/dotfiles
cd ~/dotfiles

# Run the interactive management menu
./dots

# Or run the installer directly
./dots setup
```

Once the dotfiles are applied, the same entry point is on `PATH` as `dots` — `dots`,
`dots update`, `dots apps list` — usable from any directory, with zsh and fish
completion for its commands and subcommands.

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
| **Hyprland** | Hyprland compositor with `hypridle`, `hyprlock`, `hyprpaper`, `hyprshot`, `waybar`, `vicinae`, `swaync`, `wlogout`, clipboard tooling (`cliphist`, `wl-clipboard`) and Wayland helpers |
| **Development** | `neovim`, Cursor, Zed, the [`herdr`](https://github.com/ogulcancelik/herdr) multiplexer, Git tooling (`gh`, `gh-dash`, `lazygit`, `hunk`, `tuicr`, `worktrunk`), containers (`docker`, `docker-compose`, `lazydocker`), build/task tools (`cmake`, `gcc`/`base-devel`, `just`), and Claude Code with [`ccstatusline`](https://github.com/sirmalloc/ccstatusline) |
| **Gaming** | Steam, Heroic and Discord with performance helpers (`mangohud`, `gamemode`) and controller support (`xpadneo`, `dualsensectl`) |
| **Multimedia** | Media and creation tools (`mpv`, `obs-studio`, `ffmpeg`, ImageMagick, GIMP, Inkscape, EasyEffects) |
| **Productivity** | File managers (Dolphin + Yazi), thumbnail support (`ffmpegthumbnailer`, `kdegraphics-thumbnailers`), chat apps (Slack, Telegram, plus dedicated Messenger and WhatsApp app shells), browsers (Zen, Chrome, Helium), archive tools, and themes/icons |
| **AI** | AI-powered desktop tools: `hyprvoice` speech-to-text dictation, backed by either local `whisper-cpp` models or Groq's cloud API, with an on-screen overlay showing the live microphone level |
| **Security** | ClamAV antivirus with its `clamtk` GUI |
| **Biometric** | `fprintd` fingerprint authentication |

BTRFS snapshots are deliberately absent: CachyOS's own `snapper` + `snap-pac` +
`limine-snapper-sync` stack is installed by the distro, so this repo touches
none of it.

## Structure

```
dotfiles/
├── dots                     # Management script (single entry point)
├── tools/                   # One helper per `dots` subcommand
│   ├── setup.sh             # Bootstrap (installs gum + git, runs installer)
│   ├── manage-packages.sh   # dots packages
│   ├── manage-updates.sh    # dots update
│   ├── manage-external-apps.py  # dots apps
│   ├── backup-projects.sh   # dots backup
│   └── gaming-hdr-launch.sh # dots gaming
├── install/
│   ├── installer.sh         # Main interactive installer
│   ├── distros/
│   │   └── arch.sh          # pacman/paru package functions
│   └── lib/
│       ├── common.sh        # Shared utilities
│       ├── detect.sh        # Distro detection (CachyOS/Arch family)
│       ├── services.sh      # Service management
│       ├── hyprvoice.sh     # Whisper/Groq model setup for dictation
│       └── tree_select.py   # Interactive package selector TUI
├── packages/
│   ├── common.yaml          # Tools installed via curl/git (zoxide, fnm, etc.)
│   ├── arch/
│   │   └── base.yaml        # Base packages (pacman + AUR)
│   └── groups/              # One YAML per selectable group
├── home/                    # Chezmoi source directory
│   ├── .chezmoiignore       # Conditional dotfile rules
│   ├── .chezmoiremove       # Configs to delete on apply (retired features)
│   ├── dot_config/          # ~/.config files
│   ├── dot_zshrc            # ~/.zshrc
│   └── ...
├── KEYBINDINGS.md           # Hyprland keybinding reference
└── README.md
```

## External Apps Helper

This repo includes an external apps helper, for the software pacman and paru do
not carry:

- importing an AppImage into your desktop launcher (and removing it again)
- installing a local `.deb`, `.rpm`, or `.pkg.tar.*` inside a Distrobox
  container, exported to your host launcher with `distrobox-export`
- installing straight from a GitHub release, which is how Helium is installed —
  the release source is recorded, so `dots update` keeps the app current
- updating a managed app later from its saved metadata
- guiding all of it interactively from `dots apps`

### Usage

```bash
# Open the interactive wizard
dots apps

# The full command list, which is the source of truth
dots apps help
```

The subcommands are not reproduced here on purpose — they carry their own flags
and gain more over time, and a copy in this file would rot. `dots apps help`
costs one command.

### Notes

- `dots apps` is a real interactive wizard, not just a help menu.
- The menu entry appears on desktop installs. Distrobox is *not* required for
  it to show: only some subcommands need Distrobox, and each one checks for
  itself.
- File picking starts in `~/Downloads` and falls back to `$HOME` if that folder
  does not exist.
- Distrobox install prefers choosing from existing containers before falling
  back to manual entry.
- Distrobox update uses saved managed app records instead of asking you to type
  the app name.
- `install-distrobox` tries to auto-detect the new `.desktop` file after
  install; if multiple entries are added, pass `--app your.desktop`.
- Managed app metadata is stored under
  `${XDG_STATE_HOME:-~/.local/state}/dotfiles/external-apps/`.

## Supported Distributions

This repo targets **CachyOS** exclusively. Any Arch-based distro (`ID_LIKE=arch`)
is detected and mapped to the same pacman/paru install path on a best-effort
basis; non-Arch distros are rejected by the installer.

## Manual Chezmoi Usage

The key mental model: repo files are the **source state** and your home directory is the **target state**. Editing the repo is not "live" — changes are applied when you run `chezmoi apply` (or related commands).

### First-time setup

Always run `./dots setup`. The installer is the only supported bootstrap path: it seeds `~/.config/chezmoi/chezmoi.toml` with your group selections and applies the dotfiles. Running `chezmoi init` directly is not supported — the managed configs assume packages and services the installer provisions, so a cold apply would produce broken configs for software that isn't installed.

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
3. **Hyprland users**: Press `Super+H` for the searchable keybinding list (also in [KEYBINDINGS.md](KEYBINDINGS.md))
4. **Dark/light mode**: Press `Mod+N` to toggle between Catppuccin Mocha and Latte (the prompt and Claude Code status line switch with it)
5. **Plymouth**: Reboot to see the boot splash (if configured during install)

## Included Configurations

- **Shell**: zsh and fish, both with the starship prompt, zoxide, television
- **Terminal**: kitty
- **Editor**: Neovim (AstroNvim-based), Cursor, Zed
- **Git**: hunk for diffs, tuicr for reviews, lazygit for Git operations, `gh-dash` for pull requests, WorkTrunk for worktrees
- **Multiplexer**: herdr (Zellij is retired — nothing here configures it any more)
- **File Manager**: yazi, dolphin
- **Hyprland**: hypridle, hyprlock, hyprpaper, hyprshot, waybar, vicinae, swaync, wlogout
- **AI**: hyprvoice dictation, local `whisper-cpp` or Groq (switch with `dots whisper`); recording shows an overlay with the live mic level, a microphone picker, and validate/cancel buttons
- **Claude Code**: [`ccstatusline`](https://github.com/sirmalloc/ccstatusline) status bar (flat Catppuccin-matched theme, dark/light switched), WorkTrunk worktree plugin
- **AppImage support**: Desktop installs set up the FUSE runtime for AppImages; terminal installs skip it

## License

MIT License - see [LICENSE](LICENSE) for details.
