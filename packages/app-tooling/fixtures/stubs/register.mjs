// Stand-ins for the peer dependencies the presets and the template's
// configuration files import. This repository installs none of them, so a test
// maps each specifier to a file here, then evaluates the template's file as it
// is today and the file the template switches to under the same stand-ins, and
// compares what the two produce.
//
// `stubModules({ 'eslint/config': 'eslint-config.mjs' })` maps a bare
// specifier; a function value picks the file from the importing module's URL,
// so one test can load a preset twice against two different stand-ins.
// module.registerHooks covers both `import` and `require`.
import { registerHooks } from 'node:module';

const here = (file) => new URL(file, import.meta.url).href;

export function stubModules(map) {
  registerHooks({
    resolve(specifier, context, nextResolve) {
      if (Object.hasOwn(map, specifier)) {
        const target = map[specifier];
        const file = typeof target === 'function' ? target(context.parentURL ?? '') : target;
        return { url: here(file), shortCircuit: true };
      }
      return nextResolve(specifier, context);
    },
  });
}
