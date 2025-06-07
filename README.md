# My dotfiles

Dotfiles made for my ArchLinux Gnome/Hyprland distro.

I currently use Stow GNU library to handle them.

# Setup

I made a `setup.sh` file to be able to reproduce the all thing on a fresh installation.

1. It will install `yay` and install all packages listed in the `packages.json` file.
2. It will install extra packages like `volta` and plugins for `tmux`.
3. It will setup all my dotfiles with `Stow`

# Credits

I initially started my hyprland config with that awesome [ml4w](https://www.ml4w.com/) starter kit.
After learning a lot from it, I decided to make it my own and remove any dependencies from it, but
I would definitely recommend it to anyone new to the ArchLinux Hyprland ecosystem.
