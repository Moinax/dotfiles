import { useMemo, useCallback } from "react";
import data from "../data/keybindings.json";
import type { CheatsheetData, Keybinding } from "../lib/types";
import { useTheme } from "../hooks/useTheme";
import { useSearch } from "../hooks/useSearch";
import { useFilters } from "../hooks/useFilters";
import { exportToMarkdown, downloadMarkdown } from "../lib/export";
import { Header } from "./Header";
import { SearchBar } from "./SearchBar";
import { FilterBar } from "./FilterBar";
import { KeybindingTable } from "./KeybindingTable";
import { Footer } from "./Footer";

const cheatsheet = data as CheatsheetData;
const allKeybindings = cheatsheet.keybindings as Keybinding[];

export function App() {
  const { theme, toggleTheme } = useTheme();
  const { query, setQuery, results, suggestions } = useSearch(allKeybindings);
  const { filters, toggleMode, setCategory, setSource, setPriority, resetFilters } =
    useFilters();

  // Apply filters on top of search results
  const filteredKeybindings = useMemo(() => {
    let items = results ?? allKeybindings;

    if (filters.modes.length > 0) {
      items = items.filter((kb) =>
        filters.modes.some((m) => kb.modes.includes(m))
      );
    }
    if (filters.category) {
      items = items.filter((kb) => kb.category === filters.category);
    }
    if (filters.source) {
      items = items.filter((kb) => kb.source === filters.source);
    }
    if (filters.priority) {
      items = items.filter((kb) => kb.priority === filters.priority);
    }

    return items;
  }, [results, filters]);

  const handleExport = useCallback(() => {
    const md = exportToMarkdown(filteredKeybindings, cheatsheet.leader);
    downloadMarkdown(md, "nvim-cheatsheet.md");
  }, [filteredKeybindings]);

  const handleSuggestionClick = useCallback(
    (suggestion: string) => {
      setQuery(suggestion);
    },
    [setQuery]
  );

  const handleReset = useCallback(() => {
    setQuery("");
    resetFilters();
  }, [setQuery, resetFilters]);

  return (
    <div className="app">
      <Header theme={theme} onToggleTheme={toggleTheme} onExport={handleExport} />
      <SearchBar value={query} onChange={setQuery} />
      <FilterBar
        filters={filters}
        onToggleMode={toggleMode}
        onSetCategory={setCategory}
        onSetPriority={setPriority}
        onSetSource={setSource}
      />
      <div className="results-container">
        <div className="results-header" aria-live="polite">
          <span>
            {filteredKeybindings.length} keybinding
            {filteredKeybindings.length !== 1 ? "s" : ""}
            {query ? " found" : ""}
          </span>
          <span>Sort: Priority</span>
        </div>
        <KeybindingTable
          keybindings={filteredKeybindings}
          query={query}
          suggestions={suggestions}
          onSuggestionClick={handleSuggestionClick}
          onReset={handleReset}
        />
      </div>
      <Footer
        count={filteredKeybindings.length}
        total={allKeybindings.length}
        leader={cheatsheet.leader}
      />
    </div>
  );
}
