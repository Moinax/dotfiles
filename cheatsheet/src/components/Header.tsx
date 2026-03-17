import type { Theme } from "../lib/types";

interface HeaderProps {
  theme: Theme;
  onToggleTheme: () => void;
  onExport: () => void;
}

export function Header({ theme, onToggleTheme, onExport }: HeaderProps) {
  return (
    <header className="header">
      <div className="header-left">
        <span className="header-logo" aria-hidden="true">
          ⌨️
        </span>
        <h1 className="header-title">
          <span className="header-title-short">Cheatsheet</span>
          <span className="header-title-full">Neovim Cheatsheet</span>
        </h1>
      </div>
      <div className="header-actions">
        <button
          className="icon-btn"
          onClick={onToggleTheme}
          aria-label={`Switch to ${theme === "mocha" ? "light" : "dark"} mode`}
          title={`Switch to ${theme === "mocha" ? "light" : "dark"} mode`}
        >
          {theme === "mocha" ? "☀️" : "🌙"}
        </button>
        <button
          className="export-btn"
          onClick={onExport}
          aria-label="Export as Markdown"
          title="Export as Markdown"
        >
          <span aria-hidden="true">📥</span>
          <span className="export-btn-text">Export</span>
        </button>
      </div>
    </header>
  );
}
