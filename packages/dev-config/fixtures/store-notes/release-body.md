## [1.4.0](https://github.com/acme/rn-mobile-template/compare/v1.3.2...v1.4.0) (2026-09-01)


### Features

* **auth:** stay signed in after a cold start ([#128](https://github.com/acme/rn-mobile-template/issues/128)) ([9f2c1ab](https://github.com/acme/rn-mobile-template/commit/9f2c1ab3c0d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8))
* **home:** pull to refresh on the activity list ([#131](https://github.com/acme/rn-mobile-template/issues/131)) ([4e1d0c2](https://github.com/acme/rn-mobile-template/commit/4e1d0c2a1b2c3d4e5f60718293a4b5c6d7e8f901))

### Bug Fixes

* **offline:** keep drafts when the network drops mid-save ([#134](https://github.com/acme/rn-mobile-template/issues/134)) ([a70b19c](https://github.com/acme/rn-mobile-template/commit/a70b19c9182736455463728190abcdef01234567))

### Performance Improvements

* **startup:** cut the cold start time by roughly a third ([#136](https://github.com/acme/rn-mobile-template/issues/136)) ([c3d5e78](https://github.com/acme/rn-mobile-template/commit/c3d5e7801928374655647382910abcdef0123456))

### Miscellaneous Chores

* **deps:** bump expo to 57.0.20 ([#137](https://github.com/acme/rn-mobile-template/issues/137)) ([b21f440](https://github.com/acme/rn-mobile-template/commit/b21f4409182736455463728190abcdef01234568))

## Store notes

Signing in sticks now, even after the app has been closed all day. Pull down on
the activity list to refresh it, drafts survive a dropped connection, and the
app opens noticeably faster.
