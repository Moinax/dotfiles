# Dotfiles

Personal dotfiles for Arch Linux and Fedora with optional Hyprland support.

## Features

- **Multi-distro support**: Works on Arch Linux and Fedora (extensible to other distros)
- **Interactive installer**: Beautiful TUI prompts using [gum](https://github.com/charmbracelet/gum)
- **Modular packages**: Choose what to install (Hyprland, Development, Gaming, etc.)
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
2. Let you choose package groups to install
3. Install all selected packages
4. Apply dotfiles using Chezmoi
5. Enable required services
6. Set up SSH keys and shell

## Package Groups

| Group | Description |
|-------|-------------|
| **Hyprland** | Wayland compositor with waybar, rofi, mako, wlogout |
| **Development** | Docker, Neovim, Cursor, Git tools, build tools |
| **Gaming** | Steam, Discord, gamemode |
| **Multimedia** | mpv, OBS, ffmpeg, GIMP, Inkscape |
| **Productivity** | Thunar, Timeshift, Yazi file manager, themes |

## Structure

```
dotfiles/
├── setup.sh                 # Bootstrap script (entry point)
├── install/
│   ├── installer.sh         # Main interactive installer
│   ├── distros/
│   │   ├── arch.sh          # Arch Linux package functions
│   │   └── fedora.sh        # Fedora package functions
│   └── lib/
│       ├── common.sh        # Shared utilities
│       ├── detect.sh        # Distro detection
│       └── services.sh      # Service management
├── packages/
│   ├── common.yaml          # Cross-distro tools (zoxide, volta, etc.)
│   ├── arch/
│   │   └── base.yaml        # Arch base packages
│   ├── fedora/
│   │   └── base.yaml        # Fedora base packages
│   └── groups/
│       ├── hyprland.yaml    # Hyprland + Wayland tools
│       ├── development.yaml # Dev tools
│       ├── gaming.yaml      # Gaming packages
│       ├── multimedia.yaml  # Media tools
│       └── productivity.yaml
├── home/                    # Chezmoi source directory
│   ├── .chezmoiignore       # Conditional dotfile rules
│   ├── dot_config/          # ~/.config files
│   ├── dot_zshrc            # ~/.zshrc
│   └── ...
└── README.md
```

## Adding a New Distribution

1. Create `install/distros/<distro>.sh` with package manager functions
2. Create `packages/<distro>/base.yaml` with package names
3. Add distro-specific packages to `packages/groups/*.yaml`
4. Update `install/lib/detect.sh` if needed

Example for Ubuntu:

```bash
# install/distros/ubuntu.sh
install_packages() {
    sudo apt install -y "$@"
}
```

## Manual Chezmoi Usage

If you prefer to manage dotfiles manually with Chezmoi:

```bash
# Initialize chezmoi with this repo
chezmoi init --source=~/dotfiles/home

# Preview changes
chezmoi diff

# Apply dotfiles
chezmoi apply

# Update from repo
chezmoi update
```

## Post-Installation

After running the installer:

1. **Log out and back in** for shell changes to take effect
2. **Start tmux** and press `Ctrl+b I` to install tmux plugins
3. **Add SSH key** to GitHub/GitLab (displayed during setup)
4. **Hyprland users**: Press `Super+?` to see keybindings

## Included Configurations

- **Shell**: zsh with starship prompt, zoxide, fzf
- **Terminal**: kitty
- **Editor**: Neovim (AstroNvim-based), Cursor
- **Git**: delta for diffs, lazygit
- **Multiplexer**: tmux with TPM
- **File Manager**: yazi, thunar
- **Hyprland**: hypridle, hyprlock, hyprpaper, waybar, rofi, mako

## Credits

Hyprland configuration originally inspired by [ml4w](https://www.ml4w.com/) starter kit.

## License

MIT License - see [LICENSE](LICENSE) for details.
