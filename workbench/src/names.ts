// Same rules as camel · kebab in tools/design-gen/lib.mjs (used by the tokens page to show generated names for raw JSON keys).
const parts = (name: string) => name.split(/[.\-_]/).filter(Boolean);

export const camel = (name: string) =>
  parts(name).map((p, i) => (i === 0 ? p[0].toLowerCase() + p.slice(1) : p[0].toUpperCase() + p.slice(1))).join("");

export const kebab = (name: string) =>
  parts(name).map((p) => p.replace(/([a-z0-9])([A-Z])/g, "$1-$2").toLowerCase()).join("-");
