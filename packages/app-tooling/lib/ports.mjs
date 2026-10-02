// Every port an app's local services listen on, derived from one base: the base
// plus a fixed offset per service, each with its own override variable. One
// producer, so `APP_PORT_BASE=8090 make dev` moves everything at once and two
// checkouts side by side never collide.
//
// The family's table is Metro at base+1 (8081 is Expo's own default, and the
// dev-client deep link assumes it, so the default base leaves every existing
// instruction true), the mock API at +2 and the static web preview at +3. An
// app with other services names its own table in `app-tooling.json`.
/** A port variable that is not a port; a program exits 2 on one. */
export class PortError extends Error {}

export const BASE_VAR = 'APP_PORT_BASE';
export const BASE_DEFAULT = 8080;

/** key -> { offset from the base, its own override variable, what listens there } */
export const SERVICES = {
  metro: { offset: 1, env: 'METRO_PORT', what: 'Metro / the Expo dev server' },
  mockApi: { offset: 2, env: 'MOCK_API_PORT', what: 'the mock API' },
  webPreview: { offset: 3, env: 'WEB_PREVIEW_PORT', what: 'the static web preview' },
};

/** The mock API endpoint on that port: what `EXPO_PUBLIC_API_URL` points at in dev. */
export const mockApiUrl = (port, apiPath = '/graphql') => `http://localhost:${port}${apiPath}`;

/**
 * A port from one variable: unset or empty means the fallback; anything else
 * must be a real port number, so a typo fails here rather than as a server
 * that silently never comes up.
 */
export const portFrom = (name, value, fallback) => {
  if (value === undefined || value === '') return fallback;
  if (!/^\d+$/.test(value) || Number(value) < 1 || Number(value) > 65535) {
    throw new PortError(`${name} must be a port number (1-65535), got ${JSON.stringify(value)}`);
  }
  return Number(value);
};

/** The base port from the environment (validated), else the default. */
export const baseFrom = (env, fallback = BASE_DEFAULT) => portFrom(BASE_VAR, env[BASE_VAR], fallback);

/**
 * Every service's port: its own override variable if set, else base + offset.
 *
 * @param {Record<string, string | undefined>} env
 * @param {{ base?: number, services?: typeof SERVICES }} [table]
 */
export const resolvePorts = (env, { base: baseDefault = BASE_DEFAULT, services = SERVICES } = {}) => {
  const base = baseFrom(env, baseDefault);
  const ports = { base };
  for (const [key, { offset, env: name }] of Object.entries(services)) {
    ports[key] = portFrom(name, env[name], base + offset);
  }
  return ports;
};

/**
 * Shell `export` lines for every derived value, which a Makefile's run targets
 * and the e2e scripts eval. `EXPO_PUBLIC_API_URL` is in here when there is a
 * mock API, and deliberately NOT something a mise config should export: Expo
 * bakes it into the bundle, so the committed dotenv value has to stay the
 * default a bare `expo start` picks up. `RCT_METRO_PORT` is what `expo run:ios`
 * and `expo run:android` bake into the native debug app as its dev-server port.
 */
export const envLines = (env, table = {}) => {
  const services = table.services ?? SERVICES;
  const ports = resolvePorts(env, table);
  return [
    `export ${BASE_VAR}=${ports.base}`,
    ...Object.entries(services).map(([key, { env: name }]) => `export ${name}=${ports[key]}`),
    ...('metro' in services ? [`export RCT_METRO_PORT=${ports.metro}`] : []),
    ...('mockApi' in services ? [`export EXPO_PUBLIC_API_URL=${mockApiUrl(ports.mockApi, table.apiPath)}`] : []),
  ];
};

/** The human table `ports` prints with no argument. */
export const tableLines = (env, table = {}) => {
  const services = table.services ?? SERVICES;
  const ports = resolvePorts(env, table);
  return [
    `${BASE_VAR}=${ports.base} (default ${table.base ?? BASE_DEFAULT})`,
    ...Object.entries(services).map(
      ([key, { offset, env: name, what }]) => `  ${String(ports[key]).padEnd(6)} base+${offset}  ${name}  ${what}`,
    ),
  ];
};
