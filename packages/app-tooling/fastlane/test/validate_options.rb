# Validates recorded lane arguments against the real fastlane action definitions.
#
# Runs as a child process of fastlane/test/lanes_test.rb, reading a JSON array of
# `{"action": ..., "args": {...}}` on stdin and writing a JSON array of error
# strings on stdout. It is a separate process on purpose: loading the fastlane
# gem in the test process would pull in the real `supply` (via
# `UploadToPlayStoreAction.available_options`) and clobber the supply double the
# `halt` fallback test relies on.
#
# This is the check that catches an argument the stubs happily accept and
# fastlane refuses -- an option renamed by a gem bump, or a value of the wrong
# type. `FastlaneCore::Configuration.create` raises on both; it does not require
# every mandatory option to be present, so a partial hash is fine.
require 'json'
require 'fastlane'

Fastlane.load_actions
# Fastlane.load_actions only loads the actions that ship with fastlane, so
# without this the one plugin action set in fastlane/Pluginfile would come back
# as "no such fastlane action". Loading is deliberately unguarded: a missing gem
# must fail this validator loudly rather than quietly skip the only option names
# in the suite that nobody has ever typed by hand (`bundle check` is already a
# hard precondition of `make check-release`).
Fastlane.plugin_manager.load_plugins(print_table: false)

def action_class(name)
  Fastlane::Actions.const_get("#{name.split('_').map(&:capitalize).join}Action")
rescue NameError
  nil
end

calls = JSON.parse($stdin.read)
errors = calls.filter_map do |call|
  name = call['action']
  where = "#{call['lane']} -> #{name}"
  klass = action_class(name)
  next "#{where}: no such fastlane action" if klass.nil?

  # Only the top level is symbolized: nested hashes are checked as Hash, and
  # gradle's `properties` legitimately has String keys.
  args = call['args'].to_h { |key, value| [key.to_sym, value] }
  begin
    FastlaneCore::Configuration.create(klass.available_options, args)
    nil
  rescue StandardError => e
    "#{where}: #{e.message}"
  end
end

puts JSON.generate(errors)
