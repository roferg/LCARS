// The whole point of the fixture. `import.meta.glob` is resolved by Vite AT
// TRANSFORM TIME from what is on disk, and re-resolved only when Vite's file
// WATCHER tells it the directory changed. So the number of keys the server hands
// back is a direct, observable readout of "is a watcher alive on this checkout?".
// A path assertion cannot see this; only a running server can.
const mods = import.meta.glob('./data/*.json', { eager: true });
export const ids = Object.keys(mods).sort();
export const count = ids.length;
