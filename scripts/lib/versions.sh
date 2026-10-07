#!/usr/bin/env bash
# Generated from packages/app-tooling/versions.json by scripts/self/render-versions.mjs - do not edit.
# Change a version in versions.json, then run: node scripts/self/render-versions.mjs --write
# shellcheck shell=bash
export MAESTRO_VERSION="2.10.0"
# SHA-256 of that release's maestro.zip (github.com/mobile-dev-inc/maestro,
# tag cli-2.10.0): scripts/ci/maestro-install.sh refuses any other bytes. The
# same value the consumer template's laptop installer checks.
export MAESTRO_SHA256="29b675e10cc12080e445e9bfb2e2b4e4dfb9c0f2e30d5884120d258b5e1cd991"
export ANDROID_API_LEVEL="34"
export ACTIONLINT_VERSION="1.7.12"
export SHELLCHECK_VERSION="0.11.0"
export YQ_VERSION="4.53.6"
export TYPOS_VERSION="1.50.1"
export LEFTHOOK_VERSION="2.1.14"
export ZIZMOR_VERSION="1.30.1"
export GITLEAKS_VERSION="8.30.1"
# bundletool derives the universal APK from the .aab in the android build lane;
# no runner image ships it, so scripts/ci/bundletool-install.sh downloads this
# exact release.
export BUNDLETOOL_VERSION="1.17.2"
# Machine setup (scripts/setup/*.sh): the pins that take a blank Mac or Linux
# box to one that builds and tests an Expo app. What is NOT here, on purpose:
# compileSdk, build-tools and the NDK that React Native itself builds with.
# scripts/setup/android.sh reads those from the app's
# node_modules/react-native/gradle/libs.versions.toml, so a React Native upgrade
# moves the SDK with it instead of drifting from a copy here.
#
# Android command-line tools (the `android` CLI, avdmanager). Build number and
# SHA-1 come from https://dl.google.com/android/repository/repository2-3.xml
# (remotePackage "cmdline-tools;latest"); Google publishes SHA-1 only.
export ANDROID_CMDLINE_TOOLS_BUILD="16111833"
export ANDROID_CMDLINE_TOOLS_SHA1_DARWIN_ARM64="ad03dc49bfacfd52c110b14104ea548b8a07e830"
export ANDROID_CMDLINE_TOOLS_SHA1_DARWIN_X86_64="112cf9618794a997ff273537d55bee02c22abffe"
export ANDROID_CMDLINE_TOOLS_SHA1_LINUX="e025545c62a8e64c7559119566a569fb1dec5f60"
# Packages the Android Gradle Plugin (8.12, from React Native's catalogue)
# falls back to for library modules that do not pin their own. Gradle would
# fetch them mid-build, and a dropped connection there fails the whole build
# ten minutes in, so they are installed up front, with retries.
export ANDROID_AGP_DEFAULT_PACKAGES="ndk/27.0.12077973 build-tools/35.0.0 cmake/3.22.1"
# The emulator a laptop's local E2E suite runs on, which setup creates. Not
# ANDROID_API_LEVEL above, the CI emulator's: API 36 is React Native 0.86's
# target SDK; google_apis (not playstore) boots faster and needs no account.
export SETUP_ANDROID_API_LEVEL="36"
export SETUP_ANDROID_AVD_NAME="Pixel_10_API_36"
export SETUP_ANDROID_AVD_DEVICE="pixel_10"
# CocoaPods, installed into mise's Ruby (never the system Ruby).
export COCOAPODS_VERSION="1.17.0"
# The simulator `scripts/setup/ios.sh --boot` creates if none exists.
export IOS_SIMULATOR_DEVICE_TYPE_PREFIX="com.apple.CoreSimulator.SimDeviceType.iPhone-"
