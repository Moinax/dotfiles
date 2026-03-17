import type { VimMode } from "../lib/types";
import { MODE_COLORS, MODE_LABELS } from "../lib/types";

interface ModeBadgeProps {
  mode: VimMode;
}

export function ModeBadge({ mode }: ModeBadgeProps) {
  const color = MODE_COLORS[mode];

  return (
    <span
      className="mode-badge"
      aria-label={`${MODE_LABELS[mode]} mode`}
      style={{
        background: `color-mix(in srgb, ${color} 15%, transparent)`,
        color,
      }}
    >
      {mode}
    </span>
  );
}
