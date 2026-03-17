import { useState, useEffect, useCallback } from "react";
import type { Theme } from "../lib/types";

const STORAGE_KEY = "nvim-cheatsheet-theme";

function getInitialTheme(): Theme {
  const stored = localStorage.getItem(STORAGE_KEY);
  if (stored === "mocha" || stored === "latte") return stored;
  return window.matchMedia("(prefers-color-scheme: light)").matches
    ? "latte"
    : "mocha";
}

export function useTheme() {
  const [theme, setThemeState] = useState<Theme>(getInitialTheme);

  useEffect(() => {
    document.documentElement.setAttribute("data-theme", theme);
    localStorage.setItem(STORAGE_KEY, theme);
  }, [theme]);

  const toggleTheme = useCallback(() => {
    setThemeState((t) => (t === "mocha" ? "latte" : "mocha"));
  }, []);

  return { theme, toggleTheme };
}
