// eslint/config: defineConfig flattens nested arrays; globalIgnores wraps the
// patterns in a named configuration object, as @eslint/config-helpers does.
let count = 0;
export const defineConfig = (...configs) => configs.flat(Number.POSITIVE_INFINITY);
export const globalIgnores = (ignores, name) => ({ name: name || `globalIgnores ${count++}`, ignores });
