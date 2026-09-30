// The globals Jest gives a module and a setup file: `jest.fn`, and the
// lifecycle hooks, which record the callbacks registered with them.
export const registered = { beforeEach: [], afterEach: [] };
globalThis.beforeEach = (fn) => registered.beforeEach.push(fn);
globalThis.afterEach = (fn) => registered.afterEach.push(fn);
globalThis.jest = {
  fn(implementation = () => undefined) {
    const mock = (...args) => {
      mock.calls.push(args);
      return implementation(...args);
    };
    mock.calls = [];
    return mock;
  },
};
