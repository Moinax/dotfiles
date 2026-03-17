import { useState, useMemo, useCallback, useRef, useEffect } from "react";
import Fuse from "fuse.js";
import type { Keybinding } from "../lib/types";
import { createSearchIndex } from "../lib/search";

export function useSearch(keybindings: Keybinding[]) {
  const [query, setQuery] = useState("");
  const [debouncedQuery, setDebouncedQuery] = useState("");
  const timerRef = useRef<ReturnType<typeof setTimeout>>(undefined);

  const index = useMemo(() => createSearchIndex(keybindings), [keybindings]);

  const handleQueryChange = useCallback((value: string) => {
    setQuery(value);
    if (timerRef.current) clearTimeout(timerRef.current);
    timerRef.current = setTimeout(() => {
      setDebouncedQuery(value);
    }, 150);
  }, []);

  useEffect(() => {
    return () => {
      if (timerRef.current) clearTimeout(timerRef.current);
    };
  }, []);

  const results = useMemo(() => {
    if (!debouncedQuery.trim()) return null; // null = show all
    const res = index.search(debouncedQuery);
    return res.map((r) => r.item);
  }, [index, debouncedQuery]);

  // Relaxed suggestions when 0 results
  const suggestions = useMemo(() => {
    if (results !== null && results.length === 0 && debouncedQuery.trim()) {
      const relaxed = new Fuse(keybindings, {
        keys: [
          { name: "key", weight: 0.4 },
          { name: "description", weight: 0.3 },
          { name: "tags", weight: 0.2 },
          { name: "plugin", weight: 0.1 },
        ],
        threshold: 0.6,
        ignoreLocation: true,
        minMatchCharLength: 1,
      });
      return relaxed.search(debouncedQuery, { limit: 3 }).map((r) => r.item);
    }
    return [];
  }, [results, debouncedQuery, keybindings]);

  return { query, setQuery: handleQueryChange, results, suggestions };
}
