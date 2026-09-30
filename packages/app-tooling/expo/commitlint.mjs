// The commitlint base an app `extends`: Conventional Commits, with no limit on
// body and footer lines (a pasted URL or a stack trace is not a style error).
// The closed scope list is the app's own and stays in the app's file.
//
// commitlint resolves this `extends` from this file's own directory, so
// @commitlint/config-conventional is a peer dependency the app installs.
export default {
  extends: ['@commitlint/config-conventional'],
  rules: {
    'body-max-line-length': [0],
    'footer-max-line-length': [0],
  },
};
