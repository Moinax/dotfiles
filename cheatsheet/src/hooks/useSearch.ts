import { useState, useMemo, useCallback, useRef, useEffect } from "react";
import type { Keybinding } from "../lib/types";
import { createSearchIndex, createRelaxedSearchIndex } from "../lib/search";

export function useSearch(keybindings: Keybinding[]) {
  const [query, setQuery] = useState("");
  const [debouncedQuery, setDebouncedQuery] = useState("");
  const timerRef = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);

  const index = useMemo(() => createSearchIndex(keybindings), [keybindings]);
  const relaxedIndex = useMemo(() => createRelaxedSearchIndex(keybindings), [keybindings]);

  const handleQueryChange = useCallback((value: string) => {
    setQuery(value);
    if (timerRef.current) {
      clearTimeout(timerRef.current);
      timerRef.current = undefined;
    }
    timerRef.current = setTimeout(() => {
      setDebouncedQuery(value);
    }, 150);
  }, []);

  useEffect(() => {
    return () => {
      if (timerRef.current) {
        clearTimeout(timerRef.current);
        timerRef.current = undefined;
      }
    };
  }, []);

  const results = useMemo(() => {
    if (!debouncedQuery.trim()) return null; // null = show all
    const res = index.search(debouncedQuery);
    return res.map((r) => r.item);
  }, [index, debouncedQuery]);

  // Relaxed suggestions when 0 results — reuses pre-built index
  const suggestions = useMemo(() => {
    if (results !== null && results.length === 0 && debouncedQuery.trim()) {
      return relaxedIndex.search(debouncedQuery, { limit: 3 }).map((r) => r.item);
    }
    return [];
  }, [results, debouncedQuery, relaxedIndex]);

  return { query, setQuery: handleQueryChange, results, suggestions };
}
