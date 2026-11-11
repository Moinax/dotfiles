# debug

Hardware / troubleshooting reference sheets, published via GitHub Pages so they
can be opened on a phone (e.g. while in the BIOS).

- **[bios-suspend-guide.html](https://moinax.github.io/dotfiles/debug/bios-suspend-guide.html)**
  — Z790 AORUS MASTER X: validated November 2026 S3 settings, plus historical
  CPU-idle and Smart Fan 6 notes. The local guide tracks the latest findings;
  the published copy changes only when the repository is published.

- **[nvidia-hyprland-idle-suspend-baseline.md](nvidia-hyprland-idle-suspend-baseline.md)**
  — documented baseline for NVIDIA, Hyprland, hypridle, hyprlock, DPMS, and
  suspend after removing accumulated trial workarounds.

- **[s3-deep-investigation.md](s3-deep-investigation.md)**
  — November 2026 Z790 S3 recovery: F11 I2C BAR truncation evidence,
  the separate Above 4GB MMIO BIOS assignment setting, and three successful
  real S3 cycles after correcting PCI address allocation.
