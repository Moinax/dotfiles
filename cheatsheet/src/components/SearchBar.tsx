import { useRef, useEffect } from "react";

interface SearchBarProps {
  value: string;
  onChange: (value: string) => void;
}

export function SearchBar({ value, onChange }: SearchBarProps) {
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    inputRef.current?.focus();
  }, []);

  return (
    <div className="search-container">
      <div className="search-wrapper">
        <span className="search-icon" aria-hidden="true">
          🔍
        </span>
        <input
          ref={inputRef}
          className="search-input"
          type="search"
          role="searchbox"
          aria-label="Search keybindings"
          placeholder='Search keybindings... e.g. "go to definition"'
          value={value}
          onChange={(e) => onChange(e.target.value)}
        />
        <button
          className={`search-clear ${value ? "visible" : ""}`}
          onClick={() => onChange("")}
          aria-label="Clear search"
          tabIndex={value ? 0 : -1}
        >
          ✕
        </button>
      </div>
      <div className="search-hint">
        Tip: search by key (&lt;Leader&gt;ff), action (find files), or VSCode
        shortcut (Cmd+P)
      </div>
    </div>
  );
}
