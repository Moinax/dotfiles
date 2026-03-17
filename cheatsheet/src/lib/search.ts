import Fuse, { type IFuseOptions } from "fuse.js";
import type { Keybinding } from "./types";

const fuseOptions: IFuseOptions<Keybinding> = {
  keys: [
    { name: "key", weight: 0.4 },
    { name: "description", weight: 0.3 },
    { name: "tags", weight: 0.2 },
    { name: "plugin", weight: 0.1 },
  ],
  threshold: 0.3,
  ignoreLocation: true,
  minMatchCharLength: 2,
};

export function createSearchIndex(data: Keybinding[]): Fuse<Keybinding> {
  return new Fuse(data, fuseOptions);
}

/** Relaxed search for "did you mean" suggestions */
export function suggestSearch(
  index: Fuse<Keybinding>,
  query: string,
  limit = 3
): Keybinding[] {
  const results = index.search(query, { limit });
  return results.map((r) => r.item);
}
