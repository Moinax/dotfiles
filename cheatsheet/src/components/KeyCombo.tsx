import { parseKeyCombo } from "../lib/keyParser";

interface KeyComboProps {
  keys: string;
}

export function KeyCombo({ keys }: KeyComboProps) {
  const segments = parseKeyCombo(keys);

  return (
    <span className="key-combo" aria-label={keys.replace(/<Leader>/g, "Space ")}>
      {segments.map((seg, i) => (
        <span key={i}>
          {i > 0 && !seg.isCombo && !segments[i - 1].isCombo && (
            <span className="key-separator"> </span>
          )}
          {seg.isCombo ? (
            seg.parts.map((part, j) => (
              <span key={j}>
                {j > 0 && <span className="key-separator">+</span>}
                <kbd>{part.label}</kbd>
              </span>
            ))
          ) : (
            seg.parts.map((part, j) => <kbd key={j}>{part.label}</kbd>)
          )}
        </span>
      ))}
    </span>
  );
}
