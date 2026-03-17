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

const relaxedFuseOptions: IFuseOptions<Keybinding> = {
  ...fuseOptions,
  threshold: 0.6,
  minMatchCharLength: 1,
};

export function createSearchIndex(data: Keybinding[]): Fuse<Keybinding> {
  return new Fuse(data, fuseOptions);
}

export function createRelaxedSearchIndex(data: Keybinding[]): Fuse<Keybinding> {
  return new Fuse(data, relaxedFuseOptions);
}
