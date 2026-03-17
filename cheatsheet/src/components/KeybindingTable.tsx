import type { Keybinding } from "../lib/types";
import { KeybindingRow } from "./KeybindingRow";

interface KeybindingTableProps {
  keybindings: Keybinding[];
  query: string;
  suggestions: Keybinding[];
  onSuggestionClick: (query: string) => void;
  onReset: () => void;
}

export function KeybindingTable({
  keybindings,
  query,
  suggestions,
  onSuggestionClick,
  onReset,
}: KeybindingTableProps) {
  if (keybindings.length === 0 && query) {
    return (
      <div className="empty-state">
        <div className="empty-icon">😅</div>
        <div className="empty-title">
          No keybindings match <code>{query}</code>
        </div>
        {suggestions.length > 0 && (
          <div className="suggestions-container">
            <div className="suggestions-label">Did you mean:</div>
            <div className="suggestions-list">
              {suggestions.map((s) => (
                <button
                  key={s.key + s.description}
                  onClick={() => onSuggestionClick(s.description)}
                  className="suggestion-btn"
                >
                  "{s.key}" → {s.description}
                </button>
              ))}
            </div>
          </div>
        )}
        <div className="empty-actions">
          <button className="ghost-btn" onClick={onReset}>
            Reset all filters
          </button>
        </div>
      </div>
    );
  }

  return (
    <ul className="keybinding-list" role="list" aria-live="polite">
      {keybindings.map((kb, i) => (
        <KeybindingRow
          key={kb.key + kb.modes.join("") + kb.description}
          keybinding={kb}
          style={{
            animationDelay: i < 10 ? `${i * 20}ms` : "0ms",
          }}
        />
      ))}
    </ul>
  );
}
