/** Vim/Neovim modes */
export type VimMode = "n" | "i" | "v" | "x" | "o" | "t" | "c" | "s";

/** Keybinding sources */
export type KeybindingSource =
  | "vim-builtin"
  | "astronvim-core"
  | "plugin"
  | "custom"
  | "vscode-recipe";

/** Categories */
export type KeybindingCategory =
  | "navigation"
  | "editing"
  | "text-objects"
  | "search"
  | "buffers"
  | "windows"
  | "lsp"
  | "git"
  | "terminal"
  | "ai-completion"
  | "ui-toggles";

/** Learning priority */
export type Priority = 1 | 2 | 3;

export interface Keybinding {
  key: string;
  modes: VimMode[];
  description: string;
  category: KeybindingCategory;
  source: KeybindingSource;
  plugin: string | null;
  tags: string[];
  priority: Priority;
  vscodeEquivalent?: string;
}

export interface CheatsheetData {
  version: string;
  generatedAt: string;
  leader: string;
  localLeader: string;
  keybindings: Keybinding[];
}

export type Theme = "mocha" | "latte";

export interface Filters {
  modes: VimMode[];
  category: KeybindingCategory | null;
  source: KeybindingSource | null;
  priority: Priority | null;
}

export const CATEGORY_INFO: Record<KeybindingCategory, { emoji: string; label: string }> = {
  navigation: { emoji: "🧭", label: "Navigation" },
  editing: { emoji: "✏️", label: "Editing" },
  "text-objects": { emoji: "🔤", label: "Text Objects" },
  search: { emoji: "🔍", label: "Search" },
  buffers: { emoji: "📄", label: "Buffers" },
  windows: { emoji: "🪟", label: "Windows" },
  lsp: { emoji: "🧠", label: "LSP & Code" },
  git: { emoji: "📦", label: "Git" },
  terminal: { emoji: "💻", label: "Terminal" },
  "ai-completion": { emoji: "🤖", label: "AI & Completion" },
  "ui-toggles": { emoji: "⚙️", label: "UI & Toggles" },
};

export const MODE_COLORS: Record<VimMode, string> = {
  n: "var(--ctp-blue)",
  i: "var(--ctp-green)",
  v: "var(--ctp-mauve)",
  x: "var(--ctp-peach)",
  o: "var(--ctp-red)",
  t: "var(--ctp-yellow)",
  c: "var(--ctp-flamingo)",
  s: "var(--ctp-pink)",
};

export const MODE_LABELS: Record<VimMode, string> = {
  n: "Normal",
  i: "Insert",
  v: "Visual",
  x: "Visual Block",
  o: "Operator",
  t: "Terminal",
  c: "Command",
  s: "Select",
};
