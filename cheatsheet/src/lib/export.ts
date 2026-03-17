import type { Keybinding, KeybindingCategory } from "./types";
import { CATEGORY_INFO } from "./types";

function groupBy(
  items: Keybinding[],
  key: keyof Keybinding
): Record<string, Keybinding[]> {
  const groups: Record<string, Keybinding[]> = {};
  for (const item of items) {
    const val = String(item[key]);
    if (!groups[val]) groups[val] = [];
    groups[val].push(item);
  }
  return groups;
}

export function exportToMarkdown(
  keybindings: Keybinding[],
  leader: string
): string {
  const grouped = groupBy(keybindings, "category");
  const lines: string[] = [
    "# Neovim Keybinding Cheatsheet",
    "",
    `> Leader: \`${leader}\``,
    `> Generated: ${new Date().toISOString().slice(0, 10)}`,
    "",
  ];

  for (const [category, bindings] of Object.entries(grouped)) {
    const info = CATEGORY_INFO[category as KeybindingCategory];
    const title = info ? `${info.emoji} ${info.label}` : category;
    lines.push(`## ${title}`, "");
    lines.push("| Key | Mode | Description | Source |");
    lines.push("|-----|------|-------------|--------|");
    for (const b of bindings) {
      lines.push(
        `| \`${b.key}\` | ${b.modes.join(", ")} | ${b.description} | ${b.plugin ?? b.source} |`
      );
    }
    lines.push("");
  }

  return lines.join("\n");
}

export function downloadMarkdown(content: string, filename: string): void {
  const blob = new Blob([content], { type: "text/markdown" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}
