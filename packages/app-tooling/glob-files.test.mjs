import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { globFiles, segmentPattern } from './lib/glob-files.mjs';

const root = mkdtempSync(path.join(tmpdir(), 'glob-files-'));
after(() => rmSync(root, { recursive: true, force: true }));
for (const file of [
  'ios/App/Info.plist',
  'ios/App/Supporting/Expo.plist',
  'ios/App/Images.xcassets/Splash.colorset/Contents.json',
  'ios/Other/Info.plist',
  'android/app/build.gradle',
  'android/gradle.properties',
]) {
  mkdirSync(path.join(root, path.dirname(file)), { recursive: true });
  writeFileSync(path.join(root, file), '');
}

// A link to nothing is listed by readdir and cannot be statted: ** must walk past it.
symlinkSync('/nonexistent-target', path.join(root, 'ios', 'dangling'));

test('a segment is a literal name, or has * for any run of characters inside one name', () => {
  assert.ok(segmentPattern('Info.plist').test('Info.plist'));
  assert.ok(!segmentPattern('Info.plist').test('InfoXplist'), 'the dot is a dot');
  assert.ok(segmentPattern('*.plist').test('Expo.plist'));
  assert.ok(!segmentPattern('*.plist').test('a/b.plist'), '* does not cross a slash');
  assert.ok(segmentPattern('a(b)+*').test('a(b)+zzz'), 'regular-expression characters are literal');
  assert.ok(!segmentPattern('App').test('MyApp'), 'anchored');
});

test('* stands for one directory level', () => {
  assert.deepEqual(globFiles(root, 'ios/*/Info.plist'), ['ios/App/Info.plist', 'ios/Other/Info.plist']);
  assert.deepEqual(globFiles(root, 'ios/*/Supporting/*.plist'), ['ios/App/Supporting/Expo.plist']);
  assert.deepEqual(globFiles(root, 'android/app/build.gradle'), ['android/app/build.gradle']);
});

test('** stands for any number of directories, including none', () => {
  assert.deepEqual(globFiles(root, 'ios/**/Splash.colorset'), ['ios/App/Images.xcassets/Splash.colorset']);
  assert.deepEqual(globFiles(root, 'android/**/gradle.properties'), ['android/gradle.properties']);
  assert.deepEqual(globFiles(root, '**/build.gradle'), ['android/app/build.gradle']);
});

test('a pattern that names nothing, or a missing directory, is an empty list, and a directory matches like a file', () => {
  assert.deepEqual(globFiles(root, 'ios/*/Missing.plist'), []);
  assert.deepEqual(globFiles(root, 'nowhere/**/x'), []);
  assert.deepEqual(globFiles(root, '/ios/App/'), ['ios/App']);
  assert.deepEqual(globFiles(path.join(root, 'absent'), '*'), []);
  assert.deepEqual(globFiles(root, ''), []);
});
