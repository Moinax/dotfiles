import { useState, useCallback } from "react";
import type { Filters, VimMode, KeybindingCategory, KeybindingSource, Priority } from "../lib/types";

const DEFAULT_FILTERS: Filters = {
  modes: [],
  category: null,
  source: null,
  priority: null,
};

export function useFilters() {
  const [filters, setFilters] = useState<Filters>(DEFAULT_FILTERS);

  const toggleMode = useCallback((mode: VimMode) => {
    setFilters((f) => ({
      ...f,
      modes: f.modes.includes(mode)
        ? f.modes.filter((m) => m !== mode)
        : [...f.modes, mode],
    }));
  }, []);

  const setCategory = useCallback((cat: KeybindingCategory | null) => {
    setFilters((f) => ({
      ...f,
      category: f.category === cat ? null : cat,
    }));
  }, []);

  const setSource = useCallback((src: KeybindingSource | null) => {
    setFilters((f) => ({
      ...f,
      source: f.source === src ? null : src,
    }));
  }, []);

  const setPriority = useCallback((pri: Priority | null) => {
    setFilters((f) => ({
      ...f,
      priority: f.priority === pri ? null : pri,
    }));
  }, []);

  const resetFilters = useCallback(() => {
    setFilters(DEFAULT_FILTERS);
  }, []);

  return { filters, toggleMode, setCategory, setSource, setPriority, resetFilters };
}
