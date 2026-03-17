import type {
  Filters,
  VimMode,
  KeybindingCategory,
  Priority,
  KeybindingSource,
} from "../lib/types";
import { CATEGORY_INFO, MODE_COLORS } from "../lib/types";

interface FilterBarProps {
  filters: Filters;
  onToggleMode: (mode: VimMode) => void;
  onSetCategory: (cat: KeybindingCategory | null) => void;
  onSetPriority: (pri: Priority | null) => void;
  onSetSource: (src: KeybindingSource | null) => void;
}

const MODES: VimMode[] = ["n", "i", "v", "x", "o", "t", "c", "s"];

const PRIORITIES: { value: Priority | null; label: string; emoji: string }[] = [
  { value: null, label: "All", emoji: "★" },
  { value: 1, label: "1", emoji: "🔴" },
  { value: 2, label: "2", emoji: "🟡" },
  { value: 3, label: "3", emoji: "🟢" },
];

const SOURCES: { value: KeybindingSource; label: string }[] = [
  { value: "vim-builtin", label: "Vim" },
  { value: "astronvim-core", label: "Astro" },
  { value: "plugin", label: "Plugin" },
  { value: "custom", label: "Custom" },
  { value: "vscode-recipe", label: "VSCode" },
];

export function FilterBar({
  filters,
  onToggleMode,
  onSetCategory,
  onSetPriority,
  onSetSource,
}: FilterBarProps) {
  const categories = Object.entries(CATEGORY_INFO) as [
    KeybindingCategory,
    { emoji: string; label: string },
  ][];

  return (
    <div className="filter-bar">
      {/* Mode chips */}
      <div className="filter-section">
        <span className="filter-label">Mode</span>
        {MODES.map((mode) => {
          const active = filters.modes.includes(mode);
          return (
            <button
              key={mode}
              className={`filter-chip mode-chip ${active ? "active" : ""}`}
              role="checkbox"
              aria-checked={active}
              aria-label={`Filter by ${mode} mode`}
              onClick={() => onToggleMode(mode)}
              style={
                active
                  ? {
                      background: MODE_COLORS[mode],
                      color: "var(--ctp-crust)",
                    }
                  : undefined
              }
            >
              {mode}
            </button>
          );
        })}
      </div>

      <span className="filter-divider" />

      {/* Priority chips */}
      <div className="filter-section">
        <span className="filter-label">Priority</span>
        {PRIORITIES.map((p) => {
          const active =
            p.value === null
              ? filters.priority === null
              : filters.priority === p.value;
          return (
            <button
              key={String(p.value)}
              className={`filter-chip ${active ? "active" : ""}`}
              role="checkbox"
              aria-checked={active}
              onClick={() => onSetPriority(p.value)}
              style={
                active && p.value !== null
                  ? {
                      background: "var(--ctp-lavender)",
                      color: "var(--ctp-crust)",
                    }
                  : active
                    ? {
                        background: "var(--ctp-lavender)",
                        color: "var(--ctp-crust)",
                      }
                    : undefined
              }
            >
              {p.emoji} {p.label}
            </button>
          );
        })}
      </div>

      <span className="filter-divider" />

      {/* Source chips */}
      <div className="filter-section">
        <span className="filter-label">Source</span>
        {SOURCES.map((s) => {
          const active = filters.source === s.value;
          return (
            <button
              key={s.value}
              className={`filter-chip ${active ? "active" : ""}`}
              role="checkbox"
              aria-checked={active}
              onClick={() => onSetSource(active ? null : s.value)}
              style={
                active
                  ? {
                      background: "var(--ctp-teal)",
                      color: "var(--ctp-crust)",
                    }
                  : undefined
              }
            >
              {s.label}
            </button>
          );
        })}
      </div>

      <span className="filter-divider" />

      {/* Category chips */}
      <div className="filter-section" style={{ overflowX: "auto" }}>
        <span className="filter-label">Category</span>
        {categories.map(([key, info]) => {
          const active = filters.category === key;
          return (
            <button
              key={key}
              className={`filter-chip ${active ? "active" : ""}`}
              role="checkbox"
              aria-checked={active}
              onClick={() => onSetCategory(active ? null : key)}
              style={
                active
                  ? {
                      background: "var(--ctp-lavender)",
                      color: "var(--ctp-crust)",
                    }
                  : undefined
              }
            >
              {info.emoji} {info.label}
            </button>
          );
        })}
      </div>
    </div>
  );
}
