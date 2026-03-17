import type { Keybinding } from "../lib/types";
import { CATEGORY_INFO } from "../lib/types";
import { KeyCombo } from "./KeyCombo";
import { ModeBadge } from "./ModeBadge";

interface KeybindingRowProps {
  keybinding: Keybinding;
  style?: React.CSSProperties;
}

export function KeybindingRow({ keybinding: kb, style }: KeybindingRowProps) {
  const catInfo = CATEGORY_INFO[kb.category];

  return (
    <li className="keybinding-row" style={style}>
      <div className="keybinding-key-section">
        <KeyCombo keys={kb.key} />
        <span style={{ display: "flex", gap: 4 }}>
          {kb.modes.map((m) => (
            <ModeBadge key={m} mode={m} />
          ))}
        </span>
        {kb.priority <= 2 && (
          <span
            className={`priority-indicator priority-${kb.priority}`}
            title={kb.priority === 1 ? "Must-know" : "Productive"}
          />
        )}
      </div>

      <div className="keybinding-info">
        <span className="keybinding-description">{kb.description}</span>
        <div className="keybinding-meta">
          {kb.plugin && (
            <span className="keybinding-source">↳ {kb.plugin}</span>
          )}
          <span className="category-tag">
            {catInfo.emoji} {catInfo.label}
          </span>
        </div>
        {kb.vscodeEquivalent && (
          <span className="keybinding-vscode">
            VSCode: {kb.vscodeEquivalent}
          </span>
        )}
      </div>
    </li>
  );
}
