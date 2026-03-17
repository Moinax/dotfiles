export interface KeyPart {
  type: "special" | "char";
  label: string;
}

/**
 * Parse a Vim key notation into renderable parts.
 * Examples:
 *   "<Leader>ff" → [Space] f f
 *   "<C-s>"      → [Ctrl] + [s]
 *   "ciw"        → c i w
 *   "<C-w>v"     → [Ctrl] + [w] → v
 */
export function parseKeyCombo(key: string): { parts: KeyPart[]; isCombo: boolean }[] {
  const segments: { parts: KeyPart[]; isCombo: boolean }[] = [];
  let remaining = key;

  while (remaining.length > 0) {
    // Match <...> notation
    const match = remaining.match(/^<([^>]+)>/);
    if (match) {
      const inner = match[1];
      remaining = remaining.slice(match[0].length);

      // Handle <C-x>, <S-x>, <C-S-x>
      if (inner.startsWith("C-S-") || inner.startsWith("S-C-")) {
        const char = inner.slice(4);
        segments.push({
          parts: [
            { type: "special", label: "Ctrl" },
            { type: "special", label: "Shift" },
            { type: "char", label: char },
          ],
          isCombo: true,
        });
      } else if (inner.startsWith("C-")) {
        const char = inner.slice(2);
        segments.push({
          parts: [
            { type: "special", label: "Ctrl" },
            { type: "char", label: char },
          ],
          isCombo: true,
        });
      } else if (inner.startsWith("S-")) {
        const char = inner.slice(2);
        segments.push({
          parts: [
            { type: "special", label: "Shift" },
            { type: "char", label: char },
          ],
          isCombo: true,
        });
      } else if (inner === "Leader") {
        segments.push({
          parts: [{ type: "special", label: "Space" }],
          isCombo: false,
        });
      } else if (inner === "CR") {
        segments.push({
          parts: [{ type: "special", label: "Enter" }],
          isCombo: false,
        });
      } else if (inner === "Tab") {
        segments.push({
          parts: [{ type: "special", label: "Tab" }],
          isCombo: false,
        });
      } else if (inner === "Esc") {
        segments.push({
          parts: [{ type: "special", label: "Esc" }],
          isCombo: false,
        });
      } else {
        // Generic <Something>
        segments.push({
          parts: [{ type: "special", label: inner }],
          isCombo: false,
        });
      }
    } else if (remaining.match(/^\{[^}]+\}/)) {
      // Handle {char}, {motion}, etc. — placeholder notation
      const m = remaining.match(/^\{([^}]+)\}/);
      if (m) {
        segments.push({
          parts: [{ type: "special", label: m[1] }],
          isCombo: false,
        });
        remaining = remaining.slice(m[0].length);
      }
    } else {
      // Regular character
      segments.push({
        parts: [{ type: "char", label: remaining[0] }],
        isCombo: false,
      });
      remaining = remaining.slice(1);
    }
  }

  return segments;
}
