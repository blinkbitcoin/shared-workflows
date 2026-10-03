# Unit tests for lanes/*.rb: the shared helpers, and the promotion
# logic in the iOS and Android lanes.
#
# Run: bundle exec ruby -Ifastlane/test fastlane/test/lanes_test.rb
# (also `make check-release`). stubs.rb must be loaded first: it defines the
# `UI` and fastlane-action constants shared.rb refers to, plus the
# `platform`/`lane`/`desc` DSL that turns a lane file into callable blocks.
require 'minitest/autorun'
require 'tempfile'
require 'time'
require 'tmpdir'
require 'fileutils'
require 'rbconfig'
require 'English'
require 'stubs'

require_relative '../lanes/shared'
require_relative '../lanes/ios'
require_relative '../lanes/android'
require_relative '../lanes/huawei'

class LanesTest < Minitest::Test
  def setup
    UI.reset!
    reset_calls!
    @env = ENV.to_h
  end

  def teardown
    ENV.replace(@env)
  end

  def write_file(contents)
    file = Tempfile.new('lanes-test')
    file.write(contents)
    file.close
    @tempfiles ||= []
    @tempfiles << file
    file.path
  end

  # ---------- require_env! ----------

  def test_require_env_passes_when_all_present
    ENV['A_SET'] = 'yes'
    require_env!(%w[A_SET])
  end

  def test_require_env_raises_for_missing_and_blank_keys
    ENV['A_SET'] = 'yes'
    ENV['B_BLANK'] = '   '
    ENV.delete('C_ABSENT')
    error = assert_raises(UI::UserError) { require_env!(%w[A_SET B_BLANK C_ABSENT]) }
    assert_includes error.message, 'B_BLANK'
    assert_includes error.message, 'C_ABSENT'
    refute_includes error.message, 'A_SET'
    assert_includes error.message, 'the release runbook'
  end

  # ---------- store_notes ----------

  def test_store_notes_returns_text_unchanged_when_within_limit
    ENV['STORE_NOTES_FILE'] = write_file("  Faster search and fewer crashes.\n")
    assert_equal 'Faster search and fewer crashes.', store_notes(500)
  end

  def test_store_notes_truncates_at_a_word_boundary_with_suffix
    ENV['STORE_NOTES_FILE'] = write_file(('word ' * 60).strip)
    notes = store_notes(100)

    assert notes.length <= 100, "expected <= 100 characters, got #{notes.length}"
    assert notes.end_with?(' [+more on GitHub]'), notes
    # Truncation must not split a word: everything before the suffix is whole words.
    body = notes.sub(' [+more on GitHub]', '')
    assert_equal [4], body.split.map(&:length).uniq
    refute_match(/\s\z/, body)
  end

  def test_store_notes_returns_text_unchanged_at_exactly_the_limit
    ENV['STORE_NOTES_FILE'] = write_file('a' * 50)
    assert_equal 'a' * 50, store_notes(50)
  end

  def test_store_notes_hard_cuts_text_with_no_word_boundary
    ENV['STORE_NOTES_FILE'] = write_file('a' * 200)
    notes = store_notes(50)

    assert_equal 50, notes.length
    assert notes.end_with?(' [+more on GitHub]'), notes
  end

  def test_store_notes_ignores_a_word_boundary_that_would_lose_most_of_the_window
    ENV['STORE_NOTES_FILE'] = write_file("x #{'y' * 100}")
    notes = store_notes(30)

    assert_equal 30, notes.length
    assert notes.start_with?('x yyy'), notes
  end

  def test_store_notes_handles_a_limit_smaller_than_the_suffix
    ENV['STORE_NOTES_FILE'] = write_file('hello world this is long')

    [1, 5, 10, 17, 18].each do |limit|
      notes = store_notes(limit)
      refute_nil notes, "limit #{limit} returned nil"
      assert_operator notes.length, :<=, limit
      refute_includes notes, '[+more on GitHub]', "limit #{limit} kept the suffix"
    end
  end

  def test_store_notes_returns_an_empty_string_for_a_zero_limit
    ENV['STORE_NOTES_FILE'] = write_file('hello world this is long')
    assert_equal '', store_notes(0)
  end

  def test_store_notes_raises_when_the_file_is_not_configured
    ENV.delete('STORE_NOTES_FILE')
    assert_raises(KeyError) { store_notes(500) }
  end

  # ---------- build_info ----------

  def build_info_env(version:, build_number:, info:)
    ENV['APP_VERSION'] = version
    ENV['APP_BUILD_NUMBER'] = build_number
    ENV['BUILD_INFO_FILE'] = write_file(JSON.generate(info))
  end

  def test_build_info_returns_the_parsed_file_when_it_matches
    build_info_env(version: '1.2.3', build_number: '42', info: { 'version' => '1.2.3', 'buildNumber' => 42, 'sha' => 'abc' })
    assert_equal 'abc', build_info['sha']
  end

  def test_build_info_raises_on_a_version_mismatch
    build_info_env(version: '1.2.3', build_number: '42', info: { 'version' => '1.2.4', 'buildNumber' => 42 })
    error = assert_raises(UI::UserError) { build_info }
    assert_includes error.message, '1.2.4'
    assert_includes error.message, '1.2.3'
  end

  def test_build_info_raises_on_a_build_number_mismatch
    build_info_env(version: '1.2.3', build_number: '42', info: { 'version' => '1.2.3', 'buildNumber' => 43 })
    error = assert_raises(UI::UserError) { build_info }
    assert_includes error.message, '43'
  end

  # ---------- store_action ----------

  def test_store_action_calls_the_real_action_by_default
    ENV.delete('DRY_RUN')
    result = store_action(:upload_to_testflight, ipa: '/tmp/App.ipa', groups: ['QA'])

    assert_equal [[:upload_to_testflight, { ipa: '/tmp/App.ipa', groups: ['QA'] }]], $calls
    assert_nil result
  end

  def test_store_action_passes_no_arguments_through
    ENV.delete('DRY_RUN')
    store_action(:setup_ci)
    assert_equal [[:setup_ci, {}]], $calls
  end

  def test_store_action_logs_and_skips_the_action_under_dry_run
    ENV['DRY_RUN'] = '1'
    result = store_action(:upload_to_play_store, track: 'internal', aab: '/tmp/app.aab')

    assert_empty $calls, 'DRY_RUN=1 must not call the action'
    assert_equal [], result
    assert_equal 1, UI.messages.length
    assert_equal '[dry-run] upload_to_play_store {"track":"internal","aab":"/tmp/app.aab"}', UI.messages.first
  end

  def test_store_action_is_only_disabled_by_an_exact_dry_run_flag
    ENV['DRY_RUN'] = 'true'
    store_action(:match)
    assert_equal [[:match, {}]], $calls
  end

  # ---------- ios_info_plist ----------

  # A prebuilt project has more than one Info.plist under ios/ (extension
  # targets, and the Pods project once `pod install` has run), so the app's is
  # found by scheme rather than by taking the first glob match.
  def in_ios_project(*plist_dirs)
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, 'fastlane', 'lanes'))
      plist_dirs.each do |name|
        FileUtils.mkdir_p(File.join(dir, 'ios', name))
        File.write(File.join(dir, 'ios', name, 'Info.plist'), '<plist/>')
      end
      # realpath: macOS hands out /var/folders/... for a tmpdir whose real path
      # (and so `Dir.pwd`, which repo_root anchors on) is /private/var/folders.
      Dir.chdir(dir) { yield File.realpath(dir) }
    end
  end

  def test_ios_info_plist_prefers_the_scheme_directory
    ENV['IOS_SCHEME'] = 'App'
    in_ios_project('AAAExtension', 'App') do |dir|
      assert_equal File.join(dir, 'ios', 'App', 'Info.plist'), ios_info_plist
    end
  end

  def test_ios_info_plist_falls_back_to_the_glob_when_the_scheme_has_none
    ENV['IOS_SCHEME'] = 'Missing'
    in_ios_project('AAAExtension') do |dir|
      assert_equal File.join(dir, 'ios', 'AAAExtension', 'Info.plist'), ios_info_plist
    end
  end

  def test_ios_info_plist_says_to_run_prebuild_when_there_is_none
    ENV['IOS_SCHEME'] = 'App'
    in_ios_project do
      assert_includes assert_raises(UI::UserError) { ios_info_plist }.message, 'prebuild'
    end
  end

  # ---------- store_action: secret redaction in the dry-run log ----------

  def test_dry_run_log_redacts_a_nested_api_key
    ENV['DRY_RUN'] = '1'
    store_action(:upload_to_testflight, api_key: { key_id: 'K', key_content: 'SECRET' }, ipa: '/tmp/App.ipa')

    log = UI.messages.first
    refute_includes log, 'SECRET', 'the App Store Connect .p8 must never reach the log'
    assert_includes log, '[redacted]'
    assert_includes log, '/tmp/App.ipa'
  end

  def test_dry_run_log_redacts_every_known_secret_argument
    ENV['DRY_RUN'] = '1'
    secrets = {
      json_key_data: 'SECRET', json_key: 'SECRET', password: 'SECRET',
      key_password: 'SECRET', store_password: 'SECRET', keystore_password: 'SECRET',
      match_password: 'SECRET', token: 'SECRET', api_token: 'SECRET',
      private_key: 'SECRET', key_content: 'SECRET', demo_password: 'SECRET'
    }
    store_action(:upload_to_play_store, track: 'production', **secrets)

    log = UI.messages.first
    refute_includes log, 'SECRET', log
    assert_includes log, '"track":"production"'
  end

  def test_dry_run_log_redacts_the_huawei_appgallery_connect_client_pair
    ENV['DRY_RUN'] = '1'
    store_action(:huawei_appgallery_connect, client_id: 'CLIENTIDVALUE', client_secret: 'CLIENTSECRETVALUE',
                                             app_id: '123456789', apk_path: '/tmp/app-release.aab',
                                             feedback_email: 'beta@example.com')

    log = UI.messages.first
    refute_includes log, 'CLIENTIDVALUE', 'the AppGallery Connect client id is half a credential pair'
    refute_includes log, 'CLIENTSECRETVALUE', log
    assert_includes log, '"app_id":"123456789"', 'the numeric app id is configuration, not a credential'
    assert_includes log, '/tmp/app-release.aab'
    assert_includes log, '"feedback_email":"beta@example.com"',
                    'the tester feedback address is a listing detail AppGallery shows to testers, not a credential'
  end

  def test_dry_run_log_redacts_unfamiliar_credential_shaped_names
    ENV['DRY_RUN'] = '1'
    store_action(:gradle, some_new_secret: 'SECRET', properties: { signing_password: 'SECRET' })

    refute_includes UI.messages.first, 'SECRET', UI.messages.first
  end

  def test_dry_run_log_redacts_inside_arrays
    ENV['DRY_RUN'] = '1'
    store_action(:upload_to_testflight, groups: [{ name: 'Beta', demo_password: 'SECRET' }, 'Internal'])

    log = UI.messages.first
    refute_includes log, 'SECRET', "an array argument must be descended too: #{log}"
    assert_includes log, 'Beta'
    assert_includes log, 'Internal'
  end

  def test_dry_run_log_redaction_pattern_ignores_case
    ENV['DRY_RUN'] = '1'
    store_action(:gradle, properties: { 'STORE_PASSWORD' => 'SECRET', 'JSON_Key' => 'SECRET' })

    refute_includes UI.messages.first, 'SECRET', UI.messages.first
  end

  def test_dry_run_log_keeps_non_secret_arguments_readable
    ENV['DRY_RUN'] = '1'
    store_action(:upload_to_play_store, track: 'internal', rollout: '0.1', aab: '/tmp/app.aab')

    assert_equal '[dry-run] upload_to_play_store {"track":"internal","rollout":"0.1","aab":"/tmp/app.aab"}',
                 UI.messages.first
  end

  # ---------- store_action: canned dry-run results ----------

  def test_dry_run_returns_the_shape_each_consumed_action_returns
    ENV['DRY_RUN'] = '1'

    assert_equal [], store_action(:google_play_track_version_codes, package_name: 'com.example')
    assert_equal 0, store_action(:latest_testflight_build_number, app_identifier: 'com.example')
    assert_nil store_action(:upload_to_testflight, ipa: '/tmp/App.ipa')
    assert_nil store_action(:upload_to_app_store, app_version: '1.2.3')
  end

  def test_dry_run_falls_back_to_an_empty_array_for_unlisted_actions
    ENV['DRY_RUN'] = '1'
    assert_equal [], store_action(:match, type: 'appstore')
  end

  def test_the_dry_run_idempotency_results_take_the_upload_path
    # An empty track and build number 0 must read as "nothing uploaded yet", or
    # a dry run would take the skip path and rehearse nothing.
    assert_empty DRY_RUN_RESULTS[:google_play_track_version_codes]
    assert_equal 0, DRY_RUN_RESULTS[:latest_testflight_build_number]
  end

  def test_api_key_needs_no_apple_credentials_under_dry_run
    ENV['DRY_RUN'] = '1'
    ENV['ASC_KEY_ID'] = 'KEYID'
    ENV['ASC_ISSUER_ID'] = 'ISSUER'
    ENV.delete('ASC_KEY_P8_BASE64')

    key = api_key
    assert key[:dry_run], 'a rehearsal must not sign a JWT with a real .p8'
    assert_empty $calls, 'app_store_connect_api_key opens a session; it must not run'
  end

  def test_api_key_builds_the_real_key_outside_a_dry_run
    ENV.delete('DRY_RUN')
    ENV['ASC_KEY_ID'] = 'KEYID'
    ENV['ASC_ISSUER_ID'] = 'ISSUER'
    ENV['ASC_KEY_P8_BASE64'] = 'BASE64'

    api_key
    args = $calls.find { |name, _| name == :app_store_connect_api_key }.last
    assert_equal 'KEYID', args[:key_id]
    assert args[:is_key_content_base64]
  end

  # ---------- truthy? / rollout_fraction ----------

  def test_truthy_accepts_the_string_fastlane_passes_from_the_cli
    assert truthy?('true'), 'fastlane passes `skip_signing:true` through as a String'
    assert truthy?(true)
    assert truthy?('1')
    refute truthy?('false')
    refute truthy?(nil)
    refute truthy?('')
  end

  def test_rollout_fraction_returns_the_string_supply_requires
    # supply's `rollout` ConfigItem is data_type: String; a Float is rejected by
    # FastlaneCore before the action runs.
    assert_equal '0.5', rollout_fraction('0.5')
    assert_instance_of String, rollout_fraction(50)
  end

  def test_a_whole_number_is_a_percentage
    assert_equal '0.01', rollout_fraction('1')
    assert_equal '0.01', rollout_fraction(1)
    assert_equal '0.5', rollout_fraction(50)
    assert_equal '1', rollout_fraction('100')
  end

  def test_a_decimal_is_a_fraction
    # `1` is both "1% canary" and "everybody"; only the written form separates
    # them, and guessing by magnitude would ship a canary to the whole user base.
    assert_equal '0.01', rollout_fraction('0.01')
    assert_equal '0.5', rollout_fraction(0.5)
    assert_equal '1', rollout_fraction('1.0')
  end

  def test_rollout_fraction_rejects_values_supply_would_reject
    # supply's own verify_block requires > 0.0 and <= 1.0.
    assert_raises(UI::UserError) { rollout_fraction('0') }
    assert_raises(UI::UserError) { rollout_fraction('-1') }
    assert_raises(UI::UserError) { rollout_fraction('101') }
    assert_raises(UI::UserError) { rollout_fraction('1.5') }
    assert_raises(UI::UserError) { rollout_fraction('half') }
  end

  # ---------- play_json_key_args ----------

  def test_play_credentials_prefer_inline_json_over_a_path
    ENV['PLAY_SERVICE_ACCOUNT_JSON'] = '{"type":"service_account"}'
    ENV['PLAY_SERVICE_ACCOUNT_JSON_PATH'] = '/tmp/key.json'
    assert_equal({ json_key_data: '{"type":"service_account"}' }, play_json_key_args)
  end

  def test_play_credentials_fall_back_to_a_path
    ENV.delete('PLAY_SERVICE_ACCOUNT_JSON')
    ENV['PLAY_SERVICE_ACCOUNT_JSON_PATH'] = '/tmp/key.json'
    assert_equal({ json_key: '/tmp/key.json' }, play_json_key_args)
  end

  def test_play_credentials_raise_when_neither_is_set
    ENV.delete('PLAY_SERVICE_ACCOUNT_JSON')
    ENV.delete('PLAY_SERVICE_ACCOUNT_JSON_PATH')
    error = assert_raises(UI::UserError) { play_json_key_args }
    assert_includes error.message, 'PLAY_SERVICE_ACCOUNT_JSON'
  end

  # ---------- bundletool signing arguments ----------
  #
  # A build with no keystore is the tier a repository sits in before its Play
  # credentials exist: gradle falls back to the debug keystore (the signing
  # config plugin does that and warns), and bundletool has to match it by
  # signing with its own debug key rather than being handed a keystore that is
  # not there. The difference between the two forms is four arguments, two of
  # them password file paths, so it is worth pinning rather than reading.

  def test_bundletool_args_carry_the_bundle_the_output_and_universal_mode
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'bundletool'), '#!/bin/sh')
      FileUtils.chmod(0o755, File.join(dir, 'bundletool'))
      ENV['PATH'] = dir
      args = bundletool_build_apks_args('/tmp/app.aab', '/tmp/app.apks')
      assert_includes args, 'build-apks'
      assert_includes args, '--bundle=/tmp/app.aab'
      assert_includes args, '--output=/tmp/app.apks'
      assert_includes args, '--mode=universal'
    end
  end

  def test_bundletool_args_alone_name_no_keystore
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'bundletool'), '#!/bin/sh')
      FileUtils.chmod(0o755, File.join(dir, 'bundletool'))
      ENV['PATH'] = dir
      args = bundletool_build_apks_args('/tmp/app.aab', '/tmp/app.apks')
      refute(args.any? { |a| a.start_with?('--ks') || a.start_with?('--key-pass') },
             "an unsigned build must hand bundletool no keystore: #{args.inspect}")
    end
  end

  def test_bundletool_signing_args_pass_passwords_as_files_never_inline
    ENV['ANDROID_UPLOAD_KEYSTORE_PATH'] = '/tmp/upload.keystore'
    ENV['ANDROID_UPLOAD_KEY_ALIAS'] = 'upload'
    args = bundletool_signing_args('/tmp/store.pass', '/tmp/key.pass')

    assert_includes args, '--ks-pass=file:/tmp/store.pass'
    assert_includes args, '--key-pass=file:/tmp/key.pass'
    assert_includes args, '--ks-key-alias=upload'
    # `pass:` would put the password in the process table, where the lane's
    # `log: false` cannot reach it.
    refute(args.any? { |a| a.include?('pass:') && !a.include?('file:') },
           "a password reached the argument list inline: #{args.inspect}")
  end

  # ---------- bundletool discovery ----------

  def test_bundletool_prefers_the_executable_on_path
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'bundletool'), '#!/bin/sh')
      FileUtils.chmod(0o755, File.join(dir, 'bundletool'))
      ENV['PATH'] = dir
      assert_equal ['bundletool'], bundletool_command
    end
  end

  def test_bundletool_falls_back_to_the_jar
    Dir.mktmpdir do |dir|
      jar = File.join(dir, 'bundletool-all.jar')
      File.write(jar, '')
      ENV['PATH'] = File.join(dir, 'empty')
      ENV['BUNDLETOOL_JAR'] = jar
      assert_equal ['java', '-jar', jar], bundletool_command
    end
  end

  def test_bundletool_dies_with_an_install_hint_when_absent
    Dir.mktmpdir do |dir|
      ENV['PATH'] = dir
      ENV.delete('BUNDLETOOL_JAR')
      error = assert_raises(UI::UserError) { bundletool_command }
      assert_includes error.message, 'brew install bundletool'
      assert_includes error.message, 'BUNDLETOOL_JAR'
    end
  end

  # ---------- repo root anchoring ----------

  def test_paths_are_anchored_on_the_repo_root_from_either_working_directory
    # fastlane runs every lane with the working directory set to fastlane/.
    # Relative paths looked right and silently resolved to nothing there:
    # metadata_locales returned [] and release_production wrote no notes.
    Dir.mktmpdir do |tmp|
      dir = File.realpath(tmp)
      FileUtils.mkdir_p(File.join(dir, 'fastlane', 'metadata', 'ios', 'en-US'))
      File.write(File.join(dir, 'fastlane', 'Fastfile'), '')

      Dir.chdir(File.join(dir, 'fastlane')) do
        assert_equal dir, repo_root
        assert_equal %w[en-US], metadata_locales(ios_metadata_path)
        assert_equal File.join(dir, 'artifacts', 'ios'), output_dir('ios')
      end

      Dir.chdir(dir) do
        assert_equal dir, repo_root
        assert_equal %w[en-US], metadata_locales(ios_metadata_path)
      end
    end
  end

  def test_an_explicit_output_dir_is_taken_as_given_when_absolute
    ENV['WORKFLOWS_OUTPUT_DIR'] = '/tmp/workflows-out'
    assert_equal '/tmp/workflows-out', output_dir('ios')
  end

  # ---------- artifact_dir (where a publish lane reads the binary from) ----------

  def test_artifact_dir_prefers_the_download_directory_over_the_build_output
    Dir.mktmpdir do |dir|
      assets = File.join(dir, 'assets')
      FileUtils.mkdir_p(assets)
      ENV['WORKFLOWS_ASSETS_DIR'] = assets
      ENV['WORKFLOWS_OUTPUT_DIR'] = dir
      # The publish job downloads into $WORKFLOWS_ASSETS_DIR and builds nothing, so
      # $WORKFLOWS_OUTPUT_DIR is one level above the binaries there.
      assert_equal assets, artifact_dir('ios')
      assert_equal dir, output_dir('ios')
    end
  end

  def test_artifact_dir_falls_back_to_the_output_dir_when_nothing_was_downloaded
    Dir.mktmpdir do |dir|
      ENV['WORKFLOWS_ASSETS_DIR'] = File.join(dir, 'never-created')
      ENV['WORKFLOWS_OUTPUT_DIR'] = dir
      assert_equal dir, artifact_dir('android')

      ENV.delete('WORKFLOWS_ASSETS_DIR')
      assert_equal dir, artifact_dir('android')
    end
  end

  def test_artifact_dir_falls_all_the_way_back_to_the_default_output_dir
    ENV.delete('WORKFLOWS_ASSETS_DIR')
    ENV.delete('WORKFLOWS_OUTPUT_DIR')
    assert_equal root_path('artifacts', 'ios'), artifact_dir('ios')
  end

  # ---------- metadata locales, release notes, placeholder gate ----------

  def test_metadata_locales_skips_the_non_locale_directories
    Dir.mktmpdir do |dir|
      %w[en-US de fr-FR review_information screenshots changelogs].each { |d| FileUtils.mkdir_p(File.join(dir, d)) }
      File.write(File.join(dir, 'copyright.txt'), '2026')
      assert_equal %w[de en-US fr-FR], metadata_locales(dir)
    end
  end

  def test_locale_store_notes_prefers_the_per_locale_json
    ENV['STORE_NOTES_JSON'] = write_file(JSON.generate({ 'en-US' => { 'play' => 'English notes' }, 'de' => { 'play' => 'Deutsche Notizen' } }))
    ENV['STORE_NOTES_FILE'] = write_file('fallback')

    assert_equal 'Deutsche Notizen', locale_store_notes('de', :play, 500)
  end

  def test_locale_store_notes_falls_back_when_the_locale_or_file_is_missing
    ENV['STORE_NOTES_JSON'] = write_file(JSON.generate({ 'en-US' => { 'play' => 'English notes' } }))
    ENV['STORE_NOTES_FILE'] = write_file('fallback text')

    assert_equal 'fallback text', locale_store_notes('sv-SE', :play, 500)

    ENV.delete('STORE_NOTES_JSON')
    assert_equal 'fallback text', locale_store_notes('en-US', :play, 500)
  end

  def test_locale_store_notes_truncates_to_the_store_limit
    ENV['STORE_NOTES_JSON'] = write_file(JSON.generate({ 'en-US' => { 'play' => 'a' * 900 } }))
    assert_equal 500, locale_store_notes('en-US', :play, 500).length
  end

  def test_assert_metadata_ready_names_every_file_still_holding_placeholder_text
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, 'en-US'))
      File.write(File.join(dir, 'en-US', 'description.txt'), 'Replace this text with your own.')
      File.write(File.join(dir, 'en-US', 'name.txt'), 'Real App')
      error = assert_raises(UI::UserError) { assert_metadata_ready!(dir) }
      assert_includes error.message, 'description.txt'
      refute_includes error.message, 'name.txt'
    end
  end

  def test_assert_metadata_ready_passes_once_the_placeholders_are_gone
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, 'en-US'))
      File.write(File.join(dir, 'en-US', 'description.txt'), 'A real description.')
      assert_metadata_ready!(dir)
    end
  end

  # A tree with no locales in it wrote no notes and raised nothing, so
  # release_production would have submitted for review with none.
  def test_assert_metadata_ready_refuses_a_tree_with_no_locales
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, 'review_information'))
      error = assert_raises(UI::UserError) { assert_metadata_ready!(dir) }
      assert_includes error.message, 'No locale directories'
      assert_includes error.message, dir
    end
  end

  # deliver's own exception directories, in deliver's own spelling and in the
  # case a consumer might type: LanguageFolder#valid? downcases before it
  # matches, so `appletv` and `Review_Information` are fine there too.
  def test_assert_ios_metadata_dirs_accepts_locales_and_deliver_folders_in_any_case
    Dir.mktmpdir do |dir|
      %w[en-US review_information Review_Information appleTV appletv iMessage default fonts android].each do |name|
        FileUtils.mkdir_p(File.join(dir, name))
      end
      assert_nil assert_ios_metadata_dirs!(dir)
    end
  end

  def test_assert_ios_metadata_dirs_rejects_a_screenshots_directory
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, 'en-US'))
      FileUtils.mkdir_p(File.join(dir, 'screenshots'))
      err = assert_raises(UI::UserError) { assert_ios_metadata_dirs!(dir) }
      assert_includes err.message, 'screenshots'
      assert_includes err.message, 'fastlane/screenshots/'
    end
  end

  def test_write_release_notes_refuses_a_tree_with_no_locales
    Dir.mktmpdir do |dir|
      ENV['STORE_NOTES_FILE'] = write_file('Some notes.')
      error = assert_raises(UI::UserError) do
        write_release_notes!(dir, kind: :appstore, limit: 4000)
      end
      assert_includes error.message, 'No locale directories'
    end
  end

  def test_write_release_notes_writes_nothing_under_dry_run
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, 'en-US'))
      ENV['STORE_NOTES_FILE'] = write_file('Some notes.')
      ENV['DRY_RUN'] = '1'
      written = write_release_notes!(dir, kind: :play, limit: 500, changelog_name: '42.txt')

      assert_equal [File.join(dir, 'en-US', 'changelogs', '42.txt')], written
      refute File.exist?(written.first), 'a rehearsal must not modify the working tree'
      assert(UI.messages.any? { |m| m.include?('[dry-run] would write') }, UI.messages.inspect)
    end
  end

  # ---------- truncation is one rule ----------

  def test_the_per_locale_notes_are_truncated_the_same_way_as_the_shared_file
    long = "#{'word ' * 200}end"
    ENV['STORE_NOTES_JSON'] = write_file(JSON.generate({ 'en-US' => { 'play' => long } }))
    ENV['STORE_NOTES_FILE'] = write_file(long)

    assert_equal store_notes(500), locale_store_notes('en-US', :play, 500)
    assert(locale_store_notes('en-US', :play, 500).end_with?(STORE_NOTES_SUFFIX),
           'the per-locale path used to hard-cut without the pointer')
  end

  # ---------- build-info artifact checksums ----------

  def test_write_build_info_artifacts_merges_the_checksums_into_a_copy
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'build-info', 'build-info.json')
      FileUtils.mkdir_p(File.dirname(source))
      File.write(source, JSON.generate({ 'version' => '1.2.3', 'artifacts' => {} }))
      ENV['BUILD_INFO_FILE'] = source
      out = File.join(dir, 'out')
      FileUtils.mkdir_p(out)

      written = write_build_info_artifacts!(out, aabSha256: 'aaa', apkSha256: 'bbb')

      assert_equal File.join(out, 'build-info.json'), written
      info = JSON.parse(File.read(written))
      assert_equal({ 'aabSha256' => 'aaa', 'apkSha256' => 'bbb' }, info['artifacts'])
      assert_equal '1.2.3', info['version'], 'the rest of the record must survive'
      # The source is an input to this build; rewriting it in place would make a
      # re-run depend on how far the previous one got.
      assert_equal({}, JSON.parse(File.read(source))['artifacts'])
    end
  end

  def test_write_build_info_artifacts_says_so_when_there_is_nothing_to_merge_into
    Dir.mktmpdir do |dir|
      ENV['BUILD_INFO_FILE'] = File.join(dir, 'absent.json')
      assert_nil write_build_info_artifacts!(dir, apkSha256: 'bbb')
      assert(UI.messages.any? { |m| m.include?('artifact checksums not recorded') }, UI.messages.inspect)
    end
  end

  def test_file_sha256_is_the_hex_digest_every_other_tool_prints
    file = write_file('hello')
    assert_equal '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824', file_sha256(file)
  end

  # ---------- native stack ----------

  def test_the_native_stack_is_expo_unless_the_workflows_say_otherwise
    ENV.delete('WORKFLOWS_NATIVE_STACK')
    assert_equal 'expo', native_stack
    ENV['WORKFLOWS_NATIVE_STACK'] = '  '
    assert_equal 'expo', native_stack
    ENV['WORKFLOWS_NATIVE_STACK'] = 'bare'
    assert_equal 'bare', native_stack
    ENV['WORKFLOWS_NATIVE_STACK'] = 'expo'
    assert_equal 'expo', native_stack
  end

  def test_an_unknown_native_stack_is_refused_naming_the_choices
    ENV['WORKFLOWS_NATIVE_STACK'] = 'flutter'
    error = assert_raises(UI::UserError) { native_stack }
    assert_includes error.message, 'flutter'
    assert_includes error.message, 'expo, bare'
  end

  def test_a_missing_ios_project_says_what_to_do_for_the_stack
    Dir.mktmpdir do |tmp|
      Dir.chdir(tmp) do
        ENV['WORKFLOWS_NATIVE_STACK'] = 'expo'
        assert_includes assert_raises(UI::UserError) { ios_xcodeproj }.message, 'expo prebuild'
        assert_includes assert_raises(UI::UserError) { ios_xcworkspace }.message, 'expo prebuild'
        ENV['WORKFLOWS_NATIVE_STACK'] = 'bare'
        assert_includes assert_raises(UI::UserError) { ios_xcodeproj }.message, 'commits its ios/'
        assert_includes assert_raises(UI::UserError) { ios_xcworkspace }.message, 'pod install'
      end
    end
  end

  def test_a_bare_version_mismatch_blames_the_stamp_not_prebuild
    ENV['APP_VERSION'] = '1.2.3'
    ENV['APP_BUILD_NUMBER'] = '42'
    ENV['WORKFLOWS_NATIVE_STACK'] = 'bare'
    assert_includes assert_raises(UI::UserError) { assert_project_version!('1.2.2', '42') }.message, 'the stamp did not take'
    ENV['WORKFLOWS_NATIVE_STACK'] = 'expo'
    assert_includes assert_raises(UI::UserError) { assert_project_version!('1.2.2', '42') }.message, 're-run prebuild'
  end

  # ---------- where things are, now that the lanes live in the package ----------

  def test_without_fastlane_the_repo_root_is_the_working_directory
    Dir.mktmpdir do |tmp|
      dir = File.realpath(tmp)
      Dir.chdir(dir) do
        assert_equal dir, repo_root
        assert_equal File.join(dir, 'fastlane', 'metadata'), fastlane_path('metadata')
      end
    end
  end

  def test_the_metadata_lives_in_the_fastlane_directory_fastlane_found
    Dir.mktmpdir do |tmp|
      dir = File.realpath(tmp)
      mobile = File.join(dir, 'mobile', 'fastlane')
      FileUtils.mkdir_p(mobile)
      File.write(File.join(mobile, 'Fastfile'), '')
      Dir.chdir(mobile) do
        assert_equal File.join(dir, 'mobile'), repo_root
        assert_equal File.join(mobile, 'metadata', 'ios'), ios_metadata_path
        assert_equal File.join(mobile, 'screenshots'), ios_screenshots_path
      end
    end
  end

  def test_the_verifiers_are_found_beside_the_lanes_in_the_package
    ENV.delete('WORKFLOWS_VERIFIERS_DIR')
    assert_equal File.expand_path('../../release', File.join(__dir__, '..', 'lanes')), verifiers_dir
    assert File.exist?(verify_script!('verify-ios.sh')), 'the package ships the iOS verifier beside the lanes'
    assert File.exist?(verify_script!('verify-android.sh')), 'the package ships the Android verifier beside the lanes'
  end

  def test_the_verifiers_directory_can_be_overridden_and_a_blank_override_is_ignored
    ENV['WORKFLOWS_VERIFIERS_DIR'] = '/somewhere/else'
    assert_equal '/somewhere/else', verifiers_dir
    ENV['WORKFLOWS_VERIFIERS_DIR'] = ' '
    assert_equal VERIFIERS, verifiers_dir
  end

  # ---------- assert_project_version! ----------

  def test_assert_project_version_accepts_matching_numbers
    ENV['APP_VERSION'] = '1.2.3'
    ENV['APP_BUILD_NUMBER'] = '42'
    assert_project_version!('1.2.3', 42)
  end

  def test_assert_project_version_rejects_a_stale_prebuild
    ENV['APP_VERSION'] = '1.2.3'
    ENV['APP_BUILD_NUMBER'] = '42'
    assert_includes assert_raises(UI::UserError) { assert_project_version!('1.2.2', '42') }.message, 'APP_VERSION'
    assert_includes assert_raises(UI::UserError) { assert_project_version!('1.2.3', '41') }.message, 'APP_BUILD_NUMBER'
  end

  # ---------- store listing sync: shared helpers ----------

  def test_assert_metadata_sync_enabled_accepts_common_true_values
    %w[true 1 yes].each do |value|
      ENV['STORE_METADATA_SYNC_ENABLED'] = value
      assert_nil assert_metadata_sync_enabled!
    end
  end

  def test_assert_metadata_sync_enabled_refuses_when_unset_or_false
    [nil, 'false', '0'].each do |value|
      value.nil? ? ENV.delete('STORE_METADATA_SYNC_ENABLED') : ENV['STORE_METADATA_SYNC_ENABLED'] = value
      error = assert_raises(UI::UserError) { assert_metadata_sync_enabled! }
      assert_includes error.message, 'STORE_METADATA_SYNC_ENABLED'
      assert_includes error.message, 'the release runbook'
    end
  end

  def test_with_baseline_metadata_stages_a_copy_without_the_per_version_paths
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'metadata')
      FileUtils.mkdir_p(File.join(source, 'en-US', 'changelogs'))
      File.write(File.join(source, 'en-US', 'description.txt'), 'A real description.')
      File.write(File.join(source, 'en-US', 'release_notes.txt'), 'v1 notes')
      File.write(File.join(source, 'en-US', 'changelogs', '100.txt'), 'changelog')
      source_snapshot = Dir.glob(File.join(source, '**', '*')).sort

      staged_path = nil
      with_baseline_metadata(source) do |staged|
        staged_path = staged
        assert_equal 'A real description.', File.read(File.join(staged, 'en-US', 'description.txt'))
        refute File.exist?(File.join(staged, 'en-US', 'release_notes.txt'))
        refute Dir.exist?(File.join(staged, 'en-US', 'changelogs'))
      end

      assert_equal source_snapshot, Dir.glob(File.join(source, '**', '*')).sort
      assert_equal 'A real description.', File.read(File.join(source, 'en-US', 'description.txt'))
      assert_equal 'v1 notes', File.read(File.join(source, 'en-US', 'release_notes.txt'))
      refute Dir.exist?(staged_path), 'the staged copy must not outlive the block'
    end
  end

  def test_with_baseline_metadata_drops_zero_byte_files_from_the_staged_copy
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'metadata')
      FileUtils.mkdir_p(File.join(source, 'en-US'))
      File.write(File.join(source, 'en-US', 'video.txt'), '')
      File.write(File.join(source, 'en-US', 'title.txt'), 'App')
      source_snapshot = Dir.glob(File.join(source, '**', '*')).sort

      with_baseline_metadata(source) do |staged|
        refute File.exist?(File.join(staged, 'en-US', 'video.txt')),
               'a zero-byte file PATCHes an empty value and clears the console field'
        assert_equal 'App', File.read(File.join(staged, 'en-US', 'title.txt'))
      end

      assert_equal source_snapshot, Dir.glob(File.join(source, '**', '*')).sort
      assert File.exist?(File.join(source, 'en-US', 'video.txt')), 'only the staged copy is trimmed'
    end
  end

  # ios_screenshots_path is anchored on root_path, which the existing paths
  # test exercises the same way: a scratch checkout, chdir'd into.
  def in_screenshots_root(*filenames)
    Dir.mktmpdir do |tmp|
      dir = File.realpath(tmp)
      FileUtils.mkdir_p(File.join(dir, 'fastlane', 'lanes'))
      screenshots_dir = File.join(dir, 'fastlane', 'screenshots', 'en-US')
      FileUtils.mkdir_p(screenshots_dir)
      filenames.each { |name| File.write(File.join(screenshots_dir, name), 'x') }
      Dir.chdir(dir) { yield }
    end
  end

  def test_ios_screenshots_is_false_for_an_empty_or_gitkeep_only_tree
    in_screenshots_root { refute ios_screenshots? }
    in_screenshots_root('.gitkeep') { refute ios_screenshots? }
  end

  def test_ios_screenshots_is_true_for_a_png_case_insensitively
    in_screenshots_root('01.png') { assert ios_screenshots? }
    in_screenshots_root('01.PNG') { assert ios_screenshots? }
  end

  def test_ios_app_rating_config_path_is_nil_when_absent
    Dir.mktmpdir { |dir| assert_nil ios_app_rating_config_path(dir) }
  end

  def test_ios_app_rating_config_path_is_the_path_when_present
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'app_rating_config.json')
      File.write(path, '{}')
      assert_equal path, ios_app_rating_config_path(dir)
    end
  end

  # google_play_track_version_codes has to answer differently per track for
  # these tests, which $stub_results (keyed only by action name) cannot do --
  # so the stub is swapped out directly, the same way the android halt
  # fallback test does it.
  def with_play_credentials
    ENV['PLAY_SERVICE_ACCOUNT_JSON'] = '{"type":"service_account"}'
    ENV.delete('PLAY_SERVICE_ACCOUNT_JSON_PATH')
  end

  def stub_play_track_version_codes(mapping)
    original = Object.instance_method(:google_play_track_version_codes)
    Object.send(:define_method, :google_play_track_version_codes) do |**args|
      $calls << [:google_play_track_version_codes, args]
      mapping.fetch(args[:track], [])
    end
    yield
  ensure
    Object.send(:define_method, :google_play_track_version_codes, original)
  end

  def test_play_metadata_target_returns_the_highest_code_on_production
    ENV['ANDROID_PACKAGE'] = 'com.example.app'
    with_play_credentials
    ENV.delete('PLAY_METADATA_TRACK')
    ENV.delete('DRY_RUN')
    stub_play_track_version_codes('production' => [3, 7]) do
      assert_equal ['production', 7], play_metadata_target
    end
  end

  def test_play_metadata_target_falls_through_to_the_next_track_when_empty
    ENV['ANDROID_PACKAGE'] = 'com.example.app'
    with_play_credentials
    ENV.delete('PLAY_METADATA_TRACK')
    ENV.delete('DRY_RUN')
    stub_play_track_version_codes('production' => [], 'beta' => [5]) do
      assert_equal ['beta', 5], play_metadata_target
    end
  end

  def test_play_metadata_target_only_asks_the_configured_track
    ENV['ANDROID_PACKAGE'] = 'com.example.app'
    ENV['PLAY_METADATA_TRACK'] = 'internal'
    with_play_credentials
    ENV.delete('DRY_RUN')
    stub_play_track_version_codes('internal' => [9]) do
      assert_equal ['internal', 9], play_metadata_target
      asked = $calls.select { |name, _| name == :google_play_track_version_codes }.map { |_, args| args[:track] }
      assert_equal ['internal'], asked
    end
  end

  def test_play_metadata_target_raises_naming_every_track_when_all_are_empty
    ENV['ANDROID_PACKAGE'] = 'com.example.app'
    with_play_credentials
    ENV.delete('PLAY_METADATA_TRACK')
    ENV.delete('DRY_RUN')
    stub_play_track_version_codes({}) do
      error = assert_raises(UI::UserError) { play_metadata_target }
      assert_includes error.message, 'production, beta, internal'
      assert_includes error.message, 'upload_internal'
    end
  end

  def test_play_metadata_target_falls_back_to_the_build_number_under_dry_run
    ENV['ANDROID_PACKAGE'] = 'com.example.app'
    with_play_credentials
    ENV.delete('PLAY_METADATA_TRACK')
    ENV['APP_BUILD_NUMBER'] = '42'
    ENV['DRY_RUN'] = '1'
    assert_equal ['production', 42], play_metadata_target
  end

  def test_with_asc_api_key_file_writes_a_0600_json_file_and_removes_it_after
    ENV['ASC_KEY_ID'] = 'KEYID'
    ENV['ASC_ISSUER_ID'] = 'ISSUER'
    ENV['ASC_KEY_P8_BASE64'] = 'BASE64P8'
    captured_path = nil
    with_asc_api_key_file do |path|
      captured_path = path
      assert_equal 0o600, File.stat(path).mode & 0o777
      key = JSON.parse(File.read(path))
      assert_equal 'KEYID', key['key_id']
      assert_equal 'ISSUER', key['issuer_id']
      assert_equal 'BASE64P8', key['key']
      assert_equal true, key['is_key_content_base64']
      assert_equal false, key['in_house']
    end
    refute File.exist?(captured_path)
  end

  def test_with_play_json_key_file_yields_the_configured_path_unchanged
    ENV.delete('PLAY_SERVICE_ACCOUNT_JSON')
    ENV['PLAY_SERVICE_ACCOUNT_JSON_PATH'] = '/tmp/key.json'
    with_play_json_key_file { |path| assert_equal '/tmp/key.json', path }
  end

  def test_with_play_json_key_file_writes_the_inline_json_to_a_0600_file_and_removes_it_after
    ENV['PLAY_SERVICE_ACCOUNT_JSON'] = '{"type":"service_account"}'
    ENV.delete('PLAY_SERVICE_ACCOUNT_JSON_PATH')
    captured_path = nil
    with_play_json_key_file do |path|
      captured_path = path
      assert_equal 0o600, File.stat(path).mode & 0o777
      assert_equal '{"type":"service_account"}', File.read(path)
    end
    refute File.exist?(captured_path)
  end

  def test_warn_metadata_overwrite_names_the_path_and_points_at_git_diff
    warn_metadata_overwrite!('fastlane/metadata/ios')
    assert_includes UI.messages.last, 'fastlane/metadata/ios'
    assert_includes UI.messages.last, 'git diff'
  end

  # A lane's cwd is `fastlane/`, so a repo-root-relative pathspec would match
  # nothing there and `git status --porcelain` would exit 0 on a tree the pull
  # had just rewritten. `-C <repo root>` plus absolute pathspecs is the fix.
  def test_metadata_diff_commands_runs_git_from_the_repo_root_with_absolute_pathspecs
    in_screenshots_root do
      root = repo_root
      ios = root_path('fastlane', 'metadata', 'ios')
      android = root_path('fastlane', 'metadata', 'android')
      commands = metadata_diff_commands(ios, android)

      assert_equal [
        ['git', '-C', root, 'status', '--porcelain', '--', ios, android],
        ['git', '-C', root, '--no-pager', 'diff', '--stat', '--', ios, android]
      ], commands
      commands.each do |argv|
        assert_equal '-C', argv[1]
        assert File.absolute_path?(argv[2]), "the -C root must be absolute: #{argv[2]}"
        argv.drop(argv.index('--') + 1).each do |pathspec|
          assert File.absolute_path?(pathspec), "pathspec must be absolute: #{pathspec}"
        end
      end
      assert_empty $calls, 'shared.rb must not run sh -- it is loaded without fastlane by the tests'
    end
  end
end

# Lane-level tests: the promotion logic itself, exercised through the recorded
# lane blocks with every fastlane action stubbed.
class LaneBehaviourTest < Minitest::Test
  ENV_DEFAULTS = {
    'APP_VERSION' => '1.2.3',
    'APP_BUILD_NUMBER' => '42',
    'IOS_BUNDLE_ID' => 'com.example.app',
    'IOS_SCHEME' => 'App',
    'ANDROID_PACKAGE' => 'com.example.app',
    'ASC_KEY_ID' => 'KEYID',
    'ASC_ISSUER_ID' => 'ISSUER',
    'ASC_KEY_P8_BASE64' => 'BASE64P8',
    'PLAY_SERVICE_ACCOUNT_JSON' => '{"type":"service_account"}',
    'TESTFLIGHT_INTERNAL_GROUP' => 'Internal',
    'TESTFLIGHT_EXTERNAL_GROUP' => 'Beta',
    'HUAWEI_CLIENT_ID' => 'huawei-client',
    'HUAWEI_CLIENT_SECRET' => 'huawei-secret',
    'HUAWEI_APP_ID' => '123456789'
  }.freeze

  # Env keys a test must not inherit from the shell that ran the suite.
  CLEARED_ENV = %w[
    DRY_RUN WORKFLOWS_OUTPUT_DIR WORKFLOWS_ASSETS_DIR STORE_NOTES_JSON PLAY_ROLLOUT PLAY_UPDATE_PRIORITY
    IOS_PHASED_RELEASE PLAY_SERVICE_ACCOUNT_JSON_PATH BUNDLETOOL_JAR CI
    APP_REVIEW_FIRST_NAME APP_REVIEW_LAST_NAME APP_REVIEW_PHONE APP_REVIEW_EMAIL
    APP_REVIEW_DEMO_USER APP_REVIEW_DEMO_PASSWORD APP_REVIEW_NOTES
    ANDROID_UPLOAD_KEYSTORE_PATH ANDROID_UPLOAD_KEYSTORE_PASSWORD
    ANDROID_UPLOAD_KEY_ALIAS ANDROID_UPLOAD_KEY_PASSWORD
    MATCH_GIT_URL MATCH_PASSWORD
    STORE_METADATA_SYNC_ENABLED IOS_METADATA_EDIT_LIVE PLAY_METADATA_TRACK
    HUAWEI_UPLOADS_ENABLED HUAWEI_SUBMIT_DELAY_SECONDS HUAWEI_FEEDBACK_EMAIL HUAWEI_TEST_DAYS
  ].freeze

  def setup
    UI.reset!
    reset_calls!
    @env = ENV.to_h
    CLEARED_ENV.each { |key| ENV.delete(key) }
    ENV_DEFAULTS.each { |key, value| ENV[key] = value }
  end

  def teardown
    ENV.replace(@env)
  end

  # A throwaway checkout: the metadata tree, the artifact directory and the
  # build-info/notes files the lanes read, with the lane run inside it.
  def in_project(locales: %w[en-US], notes: nil)
    Dir.mktmpdir do |dir|
      %w[ios android].each do |platform|
        locales.each { |locale| FileUtils.mkdir_p(File.join(dir, 'fastlane', 'metadata', platform, locale)) }
      end
      FileUtils.mkdir_p(File.join(dir, 'fastlane', 'metadata', 'ios', 'review_information'))
      FileUtils.mkdir_p(File.join(dir, 'artifacts', 'ios'))
      FileUtils.mkdir_p(File.join(dir, 'artifacts', 'android'))
      FileUtils.mkdir_p(File.join(dir, 'fastlane'))
      File.write(File.join(dir, 'fastlane', 'Fastfile'), '')
      FileUtils.mkdir_p(File.join(dir, 'verifiers'))
      ENV['WORKFLOWS_VERIFIERS_DIR'] = File.join(dir, 'verifiers')
      File.write(File.join(dir, 'artifacts', 'ios', 'App.ipa'), 'ipa')
      File.write(File.join(dir, 'artifacts', 'android', 'app-release.aab'), 'aab')
      File.write(File.join(dir, 'build-info.json'), JSON.generate({ 'version' => '1.2.3', 'buildNumber' => 42 }))
      File.write(File.join(dir, 'store-notes.txt'), 'Faster search and fewer crashes.')
      ENV['BUILD_INFO_FILE'] = File.join(dir, 'build-info.json')
      ENV['STORE_NOTES_FILE'] = File.join(dir, 'store-notes.txt')
      if notes
        File.write(File.join(dir, 'store-notes.json'), JSON.generate(notes))
        ENV['STORE_NOTES_JSON'] = File.join(dir, 'store-notes.json')
      end
      Dir.chdir(dir) { yield dir }
    end
  end

  # What `expo prebuild` leaves behind: a project, a workspace, and an
  # Info.plist carrying the version and build number (which is where they
  # actually live -- the pbxproj keeps Xcode's 1.0 / 1 defaults).
  def generated_ios_project(dir)
    FileUtils.mkdir_p(File.join(dir, 'ios', 'App.xcodeproj'))
    FileUtils.mkdir_p(File.join(dir, 'ios', 'App.xcworkspace'))
    FileUtils.mkdir_p(File.join(dir, 'ios', 'App'))
    File.write(File.join(dir, 'ios', 'App', 'Info.plist'), '<plist/>')
  end

  def args_for(action)
    call = $calls.find { |name, _| name == action }
    refute_nil call, "expected a #{action} call, got #{$calls.map(&:first).inspect}"
    call.last
  end

  def called?(action)
    $calls.any? { |name, _| name == action }
  end

  # ---------- ios build ----------

  def test_ios_build_skip_signing_archives_without_signing_or_export
    in_project do |dir|
      generated_ios_project(dir)
      run_lane(:ios, :build, skip_signing: 'true')

      args = args_for(:gym)
      assert args[:skip_codesigning], 'a local proof must not need a signing identity'
      assert args[:skip_package_ipa]
      refute args.key?(:export_method), 'export_method must be omitted or gym tries to export'
      assert_equal 'Release', args[:configuration]
      assert_equal root_path('artifacts', 'ios', 'App.xcarchive'), args[:archive_path]
      refute called?(:match), 'an unsigned proof must not touch the match repo'
    end
  end

  def test_ios_build_signs_and_exports_for_the_app_store
    in_project do |dir|
      generated_ios_project(dir)
      ENV['MATCH_GIT_URL'] = 'git@example.com:certs.git'
      ENV['MATCH_PASSWORD'] = 'secret'
      run_lane(:ios, :build)

      assert_equal 'appstore', args_for(:match)[:type]
      assert args_for(:match)[:readonly], 'CI never creates certificates'
      args = args_for(:gym)
      assert_equal 'app-store', args[:export_method]
      assert_equal({ manageAppVersionAndBuildNumber: false }, args[:export_options])
    end
  end

  def test_ios_build_refuses_a_project_whose_numbers_do_not_match_the_release
    in_project do |dir|
      generated_ios_project(dir)
      stub_result(:CFBundleVersion, '41')
      error = assert_raises(UI::UserError) { run_lane(:ios, :build, skip_signing: 'true') }
      assert_includes error.message, 'APP_BUILD_NUMBER'
      refute called?(:gym), 'nothing may be archived once the numbers disagree'
    end
  end

  # A bare app has no prebuild to put the release's numbers in the project, so
  # the lane stamps them and reads them back before archiving.
  def test_a_bare_ios_build_stamps_the_release_numbers_into_the_project_and_checks_them
    ENV['WORKFLOWS_NATIVE_STACK'] = 'bare'
    in_project do |dir|
      generated_ios_project(dir)
      run_lane(:ios, :build, skip_signing: 'true')

      project = File.realpath(File.join(dir, 'ios', 'App.xcodeproj'))
      assert_equal project, File.realpath(args_for(:increment_version_number)[:xcodeproj])
      assert_equal project, File.realpath(args_for(:increment_build_number)[:xcodeproj])
      assert_equal ENV['APP_VERSION'], args_for(:increment_version_number)[:version_number]
      assert_equal ENV['APP_BUILD_NUMBER'], args_for(:increment_build_number)[:build_number]
      assert_equal ENV['IOS_SCHEME'], args_for(:get_version_number)[:target]
      refute called?(:get_info_plist_value), 'a bare project is not read through a prebuilt Info.plist'
      names = $calls.map(&:first)
      assert_operator names.index(:increment_build_number), :<, names.index(:gym), 'stamped before the archive'
    end
  end

  def test_a_bare_ios_build_refuses_a_project_that_kept_other_numbers
    ENV['WORKFLOWS_NATIVE_STACK'] = 'bare'
    in_project do |dir|
      generated_ios_project(dir)
      stub_result(:get_build_number, '41')
      error = assert_raises(UI::UserError) { run_lane(:ios, :build, skip_signing: 'true') }
      assert_includes error.message, 'APP_BUILD_NUMBER'
      refute called?(:gym), 'nothing may be archived once the numbers disagree'
    end
  end

  def test_an_expo_ios_build_stamps_nothing
    ENV['WORKFLOWS_NATIVE_STACK'] = 'expo'
    in_project do |dir|
      generated_ios_project(dir)
      run_lane(:ios, :build, skip_signing: 'true')
      refute called?(:increment_version_number)
      refute called?(:increment_build_number)
    end
  end

  def test_ios_build_says_prebuild_has_not_run
    in_project do
      error = assert_raises(UI::UserError) { run_lane(:ios, :build, skip_signing: 'true') }
      assert_includes error.message, 'prebuild'
    end
  end

  # ---------- ios verify ----------

  def test_ios_verify_names_the_missing_script
    in_project do
      error = assert_raises(UI::UserError) { run_lane(:ios, :verify) }
      assert_includes error.message, File.join('verifiers', 'verify-ios.sh')
      assert_includes error.message, 'Missing'
    end
  end

  def test_ios_verify_passes_no_signing_through_to_the_script
    in_project do |dir|
      File.write(File.join(dir, 'verifiers', 'verify-ios.sh'), '#!/bin/bash')
      run_lane(:ios, :verify, skip_signing: 'true')

      command = args_for(:sh)
      assert_equal 'bash', command[0]
      assert_equal File.join(dir, 'verifiers', 'verify-ios.sh'), command[1]
      assert_includes command, '--no-signing'
    end
  end

  # fastlane runs actions from fastlane/, and a verifier started there would
  # read the wrong directory as the repository and skip its root-relative checks.
  def test_the_verify_lanes_start_the_verifier_at_the_repository_root
    in_project do |dir|
      File.write(File.join(dir, 'verifiers', 'verify-ios.sh'), '#!/bin/bash')
      File.write(File.join(dir, 'verifiers', 'verify-android.sh'), '#!/bin/bash')
      FileUtils.mkdir_p(File.join(dir, 'artifacts', 'android'))
      %w[app-release.aab app-universal.apk].each { |name| File.write(File.join(dir, 'artifacts', 'android', name), 'x') }
      started = []
      original = Object.instance_method(:sh)
      Object.send(:define_method, :sh) { |*_command, **_options| started << Dir.pwd }
      begin
        Dir.chdir(File.join(dir, 'fastlane')) do
          run_lane(:ios, :verify, skip_signing: 'true')
          run_lane(:android, :verify)
        end
      ensure
        Object.send(:define_method, :sh, original)
      end
      assert_equal [File.realpath(dir)] * 2, started.map { |path| File.realpath(path) }
    end
  end

  # ---------- ios upload_internal ----------

  def test_ios_upload_internal_skips_when_the_build_number_already_exists
    in_project do
      stub_result(:latest_testflight_build_number, 42)
      run_lane(:ios, :upload_internal)

      refute called?(:upload_to_testflight), 'a retried job must not fail on a duplicate build'
      assert(UI.messages.any? { |m| m.include?('skipping upload') }, UI.messages.inspect)
    end
  end

  def test_ios_upload_internal_uploads_a_new_build_number
    in_project do
      stub_result(:latest_testflight_build_number, 41)
      run_lane(:ios, :upload_internal)

      args = args_for(:upload_to_testflight)
      assert_equal root_path('artifacts', 'ios', 'App.ipa'), args[:ipa]
      assert_equal 'Faster search and fewer crashes.', args[:changelog]
      assert_equal ['Internal'], args[:groups]
      refute args[:distribute_external], 'internal uploads never go to external testers'
      assert args[:skip_submission]
    end
  end

  # The publish job never builds: `publish-store.yml` downloads the build job's
  # artifacts into $WORKFLOWS_ASSETS_DIR, one level *below* $WORKFLOWS_OUTPUT_DIR. Reading
  # the output directory here handed pilot a path with no ipa at it, on every
  # single run.
  def test_ios_upload_internal_reads_the_ipa_from_the_download_directory
    in_project do |dir|
      assets = File.join(dir, 'workflows-out', 'assets')
      FileUtils.mkdir_p(assets)
      File.write(File.join(assets, 'App.ipa'), 'ipa')
      ENV['WORKFLOWS_OUTPUT_DIR'] = File.join(dir, 'workflows-out')
      ENV['WORKFLOWS_ASSETS_DIR'] = assets
      stub_result(:latest_testflight_build_number, 41)
      run_lane(:ios, :upload_internal)

      assert_equal File.join(assets, 'App.ipa'), args_for(:upload_to_testflight)[:ipa]
    end
  end

  def test_ios_upload_internal_lets_an_explicit_ipa_win_over_both_directories
    in_project do |dir|
      ENV['WORKFLOWS_ASSETS_DIR'] = dir
      stub_result(:latest_testflight_build_number, 41)
      run_lane(:ios, :upload_internal, ipa: '/somewhere/else/App.ipa')

      assert_equal '/somewhere/else/App.ipa', args_for(:upload_to_testflight)[:ipa]
    end
  end

  def test_ios_upload_internal_refuses_an_artifact_from_another_release
    in_project do |dir|
      File.write(File.join(dir, 'build-info.json'), JSON.generate({ 'version' => '9.9.9', 'buildNumber' => 42 }))
      assert_raises(UI::UserError) { run_lane(:ios, :upload_internal) }
      refute called?(:upload_to_testflight)
    end
  end

  # ---------- ios promote_beta ----------

  def test_ios_promote_beta_distributes_the_existing_build_without_re_uploading
    in_project do
      run_lane(:ios, :promote_beta)

      args = args_for(:upload_to_testflight)
      assert args[:distribute_only], 'beta must ship the exact binary internal testers saw'
      assert args[:distribute_external]
      assert_equal ['Beta'], args[:groups]
      assert_equal '42', args[:build_number]
      refute args.key?(:ipa), 'distribute_only must not carry an artifact'
    end
  end

  def test_ios_promote_beta_sends_review_contact_details_in_pilots_key_names
    in_project do
      ENV['APP_REVIEW_EMAIL'] = 'review@example.com'
      ENV['APP_REVIEW_DEMO_USER'] = 'demo'
      run_lane(:ios, :promote_beta)

      info = args_for(:upload_to_testflight)[:beta_app_review_info]
      assert_equal 'review@example.com', info[:contact_email]
      assert_equal 'demo', info[:demo_account_name]
      assert info[:demo_account_required]
      refute info.key?(:contact_first_name), 'a blank would erase the name in App Store Connect'
    end
  end

  def test_ios_promote_beta_omits_review_info_entirely_when_nothing_is_configured
    in_project do
      # pilot PATCHes every key it is handed (build_manager.rb keys off
      # `info.key?`, not on the value), so sending a hash full of blanks
      # silently clears the beta review contact someone set in the web UI.
      run_lane(:ios, :promote_beta)
      refute args_for(:upload_to_testflight).key?(:beta_app_review_info)
    end
  end

  def test_ios_promote_beta_sends_no_demo_account_required_without_a_demo_user
    in_project do
      ENV['APP_REVIEW_EMAIL'] = 'review@example.com'
      run_lane(:ios, :promote_beta)

      assert_equal({ contact_email: 'review@example.com' },
                   args_for(:upload_to_testflight)[:beta_app_review_info])
    end
  end

  # ---------- ios release_production ----------

  def test_ios_release_production_writes_release_notes_per_locale_directory
    notes = {
      'en-US' => { 'appstore' => 'English App Store notes.' },
      'de' => { 'appstore' => 'Deutsche App-Store-Notizen.' }
    }
    in_project(locales: %w[en-US de], notes: notes) do
      run_lane(:ios, :release_production)

      assert_equal "English App Store notes.\n", File.read('fastlane/metadata/ios/en-US/release_notes.txt')
      assert_equal "Deutsche App-Store-Notizen.\n", File.read('fastlane/metadata/ios/de/release_notes.txt')
      refute File.exist?('fastlane/metadata/ios/review_information/release_notes.txt'),
             'review_information is not a locale'
    end
  end

  def test_ios_release_production_submits_metadata_only
    in_project do
      ENV['IOS_PHASED_RELEASE'] = 'true'
      run_lane(:ios, :release_production)

      args = args_for(:upload_to_app_store)
      assert args[:skip_binary_upload], 'the binary is already in App Store Connect'
      assert_equal root_path('fastlane', 'metadata', 'ios'), args[:metadata_path]
      assert args[:submit_for_review]
      assert args[:automatic_release]
      assert args[:phased_release]
      refute args[:run_precheck_before_submit]
      refute args.key?(:app_review_information),
             'deliver derives demoAccountRequired from this hash: blanks would clear it'
    end
  end

  def test_ios_release_production_refuses_placeholder_metadata
    in_project do
      File.write('fastlane/metadata/ios/en-US/description.txt', 'Replace this text with the story of your own app.')
      error = assert_raises(UI::UserError) { run_lane(:ios, :release_production) }
      assert_includes error.message, 'description.txt'
      refute called?(:upload_to_app_store)
    end
  end

  def test_ios_release_production_refuses_a_screenshots_directory
    in_project do
      FileUtils.mkdir_p('fastlane/metadata/ios/screenshots')
      error = assert_raises(UI::UserError) { run_lane(:ios, :release_production) }
      assert_includes error.message, 'screenshots'
      refute called?(:upload_to_app_store)
    end
  end

  # ---------- ios sync_metadata ----------

  def test_ios_sync_metadata_refuses_when_disabled
    in_project do
      error = assert_raises(UI::UserError) { run_lane(:ios, :sync_metadata) }
      assert_includes error.message, 'STORE_METADATA_SYNC_ENABLED'
      refute called?(:upload_to_app_store)
    end
  end

  def test_ios_sync_metadata_pushes_metadata_only
    ENV['STORE_METADATA_SYNC_ENABLED'] = 'true'
    in_project do
      run_lane(:ios, :sync_metadata)

      args = args_for(:upload_to_app_store)
      assert args[:skip_binary_upload], 'sync_metadata must never touch the binary'
      assert args[:skip_app_version_update], 'sync_metadata must never move the version'
      assert_equal false, args[:submit_for_review], 'deliver defaults this to true'
      assert_equal false, args[:run_precheck_before_submit], 'deliver defaults this to true'
      assert_equal false, args[:edit_live], 'deliver defaults this to true'
      assert args[:force]
      assert_equal false, args[:skip_metadata], 'deliver defaults this to true'
      refute args.key?(:app_version)
      refute args.key?(:automatic_release)
      refute args.key?(:phased_release)
      refute args.key?(:auto_release_date)
      refute args.key?(:submission_information)
      refute_equal root_path('fastlane', 'metadata', 'ios'), args[:metadata_path],
                    'a staged copy must be pushed, never the working tree'
    end
  end

  def test_ios_sync_metadata_excludes_release_notes_from_the_staged_tree
    ENV['STORE_METADATA_SYNC_ENABLED'] = 'true'
    in_project do
      File.write('fastlane/metadata/ios/en-US/description.txt', 'The story of this app.')
      File.write('fastlane/metadata/ios/en-US/release_notes.txt', "What's new.")
      run_lane(:ios, :sync_metadata)

      snapshot = $metadata_snapshots.last
      assert_includes snapshot, 'en-US/description.txt'
      refute_includes snapshot, 'en-US/release_notes.txt'
      assert File.exist?('fastlane/metadata/ios/en-US/release_notes.txt'),
             'the working tree copy must survive: only the staged copy is trimmed'
    end
  end

  def test_ios_sync_metadata_omits_review_information_when_unconfigured
    ENV['STORE_METADATA_SYNC_ENABLED'] = 'true'
    in_project do
      run_lane(:ios, :sync_metadata)

      refute args_for(:upload_to_app_store).key?(:app_review_information)
      refute $metadata_snapshots.last.any? { |f| f.start_with?('review_information') },
             'an empty review_information would clear the contact already on file'
    end
  end

  def test_ios_sync_metadata_includes_review_information_when_configured
    ENV['STORE_METADATA_SYNC_ENABLED'] = 'true'
    ENV['APP_REVIEW_EMAIL'] = 'review@example.com'
    in_project do
      run_lane(:ios, :sync_metadata)

      args = args_for(:upload_to_app_store)
      assert_equal 'review@example.com', args[:app_review_information][:email_address]
      assert $metadata_snapshots.last.any? { |f| f.start_with?('review_information') }
    end
  end

  def test_ios_sync_metadata_live_option_edits_the_live_version_only
    ENV['STORE_METADATA_SYNC_ENABLED'] = 'true'
    ENV['APP_REVIEW_EMAIL'] = 'review@example.com'
    in_project do
      run_lane(:ios, :sync_metadata, live: true)

      args = args_for(:upload_to_app_store)
      assert args[:edit_live]
      assert args[:skip_screenshots]
      refute args.key?(:app_review_information), 'review detail is not editable in live mode'
      # Live mode is the path that does *not* wait: it fetches the live
      # version first, with no retry (deliver/lib/deliver/upload_metadata.rb:107).
      refute UI.messages.any? { |m| m.include?('20 minutes') }, UI.messages.inspect
    end
  end

  # The default path is the slow one: with no version in "Prepare for
  # Submission" deliver retries for about 20 minutes and then fails without
  # writing (upload_metadata.rb:464-481, :557-560). The lane says so up front.
  def test_ios_sync_metadata_warns_that_a_version_in_preparation_is_needed
    ENV['STORE_METADATA_SYNC_ENABLED'] = 'true'
    in_project do
      run_lane(:ios, :sync_metadata)

      assert UI.messages.any? { |m| m.include?('20 minutes') && m.include?('IOS_METADATA_EDIT_LIVE') },
             UI.messages.inspect
    end
  end

  def test_ios_sync_metadata_edit_live_env_edits_the_live_version_only
    ENV['STORE_METADATA_SYNC_ENABLED'] = 'true'
    ENV['IOS_METADATA_EDIT_LIVE'] = 'true'
    ENV['APP_REVIEW_EMAIL'] = 'review@example.com'
    in_project do
      run_lane(:ios, :sync_metadata)

      args = args_for(:upload_to_app_store)
      assert args[:edit_live]
      assert args[:skip_screenshots]
      refute args.key?(:app_review_information)
    end
  end

  def test_ios_sync_metadata_stages_screenshots_as_a_sibling_of_the_metadata_tree
    ENV['STORE_METADATA_SYNC_ENABLED'] = 'true'
    in_project do |dir|
      FileUtils.mkdir_p(File.join(dir, 'fastlane', 'screenshots', 'en-US'))
      File.write(File.join(dir, 'fastlane', 'screenshots', 'en-US', 'home.png'), 'png')
      run_lane(:ios, :sync_metadata)

      args = args_for(:upload_to_app_store)
      refute args[:skip_screenshots]
      assert args[:overwrite_screenshots]
      refute_nil args[:screenshots_path]
      refute args[:screenshots_path].start_with?(args[:metadata_path]),
             'screenshots is the one directory name deliver rejects under metadata_path'
    end
  end

  def test_ios_sync_metadata_skips_screenshots_when_none_are_staged
    ENV['STORE_METADATA_SYNC_ENABLED'] = 'true'
    in_project do
      run_lane(:ios, :sync_metadata)

      args = args_for(:upload_to_app_store)
      assert args[:skip_screenshots]
      refute args.key?(:screenshots_path)
    end
  end

  def test_ios_sync_metadata_passes_app_rating_config_path_only_when_present
    ENV['STORE_METADATA_SYNC_ENABLED'] = 'true'
    in_project do
      run_lane(:ios, :sync_metadata)
      refute args_for(:upload_to_app_store).key?(:app_rating_config_path)
    end

    reset_calls!
    in_project do
      File.write('fastlane/metadata/ios/app_rating_config.json', '{}')
      run_lane(:ios, :sync_metadata)

      args = args_for(:upload_to_app_store)
      refute_nil args[:app_rating_config_path]
      assert args[:app_rating_config_path].start_with?(args[:metadata_path]),
             'the rating config must come from the staged tree, not the working tree'
    end
  end

  def test_ios_sync_metadata_refuses_placeholder_metadata
    ENV['STORE_METADATA_SYNC_ENABLED'] = 'true'
    in_project do
      File.write('fastlane/metadata/ios/en-US/description.txt', 'Replace this text with the story of your own app.')
      error = assert_raises(UI::UserError) { run_lane(:ios, :sync_metadata) }
      assert_includes error.message, 'description.txt'
      refute called?(:upload_to_app_store)
    end
  end

  def test_ios_sync_metadata_refuses_a_tree_with_no_locales
    ENV['STORE_METADATA_SYNC_ENABLED'] = 'true'
    in_project(locales: []) do
      error = assert_raises(UI::UserError) { run_lane(:ios, :sync_metadata) }
      assert_includes error.message, 'No locale directories'
      refute called?(:upload_to_app_store)
    end
  end

  def test_ios_sync_metadata_refuses_a_screenshots_directory_inside_metadata
    ENV['STORE_METADATA_SYNC_ENABLED'] = 'true'
    in_project do
      FileUtils.mkdir_p('fastlane/metadata/ios/screenshots')
      error = assert_raises(UI::UserError) { run_lane(:ios, :sync_metadata) }
      assert_includes error.message, 'screenshots'
      refute called?(:upload_to_app_store)
    end
  end

  # ---------- ios pull_metadata ----------

  def test_ios_pull_metadata_dry_run_logs_and_makes_no_sh_call
    ENV['DRY_RUN'] = '1'
    in_project do
      run_lane(:ios, :pull_metadata)
      assert UI.messages.any? { |m| m.include?('[dry-run]') }, UI.messages.inspect
      refute called?(:sh)
    end
  end

  def test_ios_pull_metadata_downloads_metadata_and_screenshots_then_reports_the_diff
    in_project do
      run_lane(:ios, :pull_metadata)

      sh_calls = $calls.select { |name, _| name == :sh }.map(&:last)
      assert_equal 4, sh_calls.length, sh_calls.inspect

      metadata_call = sh_calls[0]
      assert_equal %w[bundle exec fastlane deliver download_metadata], metadata_call[0, 5]
      assert_includes metadata_call, '--api_key_path'
      assert_includes metadata_call, '--app_identifier'
      assert_includes metadata_call, 'com.example.app'
      # deliver's download_metadata ignores use_live_version -- it takes the
      # latest App Store version and consults only app_version
      # (deliver/lib/deliver/commands_generator.rb:172-200) -- so the lane must
      # not pass an option that suggests a choice it does not make.
      refute_includes metadata_call, '--use_live_version'
      assert_includes metadata_call, '--metadata_path'
      assert_includes metadata_call, root_path('fastlane', 'metadata', 'ios')
      assert_includes metadata_call, '--force'

      screenshots_call = sh_calls[1]
      assert_equal %w[bundle exec fastlane deliver download_screenshots], screenshots_call[0, 5]
      assert_includes screenshots_call, '--screenshots_path'
      assert_includes screenshots_call, root_path('fastlane', 'screenshots')
      refute_includes screenshots_call, '--use_live_version'

      # The diff runs from the repo root with absolute pathspecs: the lane's
      # own cwd is `fastlane/`, where a relative pathspec matches nothing.
      ios = root_path('fastlane', 'metadata', 'ios')
      shots = root_path('fastlane', 'screenshots')
      assert_equal ['git', '-C', repo_root, 'status', '--porcelain', '--', ios, shots], sh_calls[2]
      assert_equal ['git', '-C', repo_root, '--no-pager', 'diff', '--stat', '--', ios, shots], sh_calls[3]
      [ios, shots].each { |path| assert File.absolute_path?(path), path }

      refute sh_calls.flatten.any? { |arg| arg.to_s.include?('BASE64P8') }, 'no credential value in any argv'
    end
  end

  # ---------- ios phased ----------

  def test_ios_phased_drives_the_live_versions_phased_release
    in_project do
      run_lane(:ios, :phased, action: 'pause')
      assert_equal [[:phased_release, { action: 'pause' }]], $calls.select { |name, _| name == :phased_release }
    end
  end

  def test_ios_phased_rejects_an_unknown_action
    in_project do
      error = assert_raises(UI::UserError) { run_lane(:ios, :phased, action: 'stop') }
      assert_includes error.message, 'pause|resume|complete'
    end
  end

  # ---------- android upload_internal ----------

  def test_android_upload_internal_skips_a_version_code_the_track_already_has
    in_project do
      stub_result(:google_play_track_version_codes, [41, 42])
      run_lane(:android, :upload_internal)

      refute called?(:upload_to_play_store), 'Play rejects a duplicate version code'
      assert(UI.messages.any? { |m| m.include?('skipping upload') }, UI.messages.inspect)
    end
  end

  def test_android_upload_internal_writes_the_changelog_supply_reads
    in_project(notes: { 'en-US' => { 'play' => 'Kortare notes.' } }) do
      stub_result(:google_play_track_version_codes, [41])
      run_lane(:android, :upload_internal)

      assert_equal "Kortare notes.\n", File.read('fastlane/metadata/android/en-US/changelogs/42.txt')
      args = args_for(:upload_to_play_store)
      assert_equal 'internal', args[:track]
      assert_equal 42, args[:version_code]
      assert_equal root_path('artifacts', 'android', 'app-release.aab'), args[:aab]
      assert args[:skip_upload_metadata], 'the public listing is synced only from release_production'
      refute args[:skip_upload_changelogs]
      assert_equal '{"type":"service_account"}', args[:json_key_data]
    end
  end

  # A Play app that has never been published rejects a completed release, so the
  # first upload has to be a draft; that is what PLAY_RELEASE_STATUS is for.
  def test_play_release_status_is_completed_unless_the_environment_says_draft
    ENV.delete('PLAY_RELEASE_STATUS')
    assert_equal 'completed', play_release_status

    ENV['PLAY_RELEASE_STATUS'] = '  '
    assert_equal 'completed', play_release_status, 'an unset repository variable reaches a lane as an empty string'

    ENV['PLAY_RELEASE_STATUS'] = 'draft'
    assert_equal 'draft', play_release_status

    ENV['PLAY_RELEASE_STATUS'] = ' completed '
    assert_equal 'completed', play_release_status
  end

  def test_play_release_status_refuses_anything_else
    ENV['PLAY_RELEASE_STATUS'] = 'halted'
    error = assert_raises(UI::UserError) { play_release_status }
    assert_match(/PLAY_RELEASE_STATUS must be completed or draft \(got "halted"\)/, error.message)
  end

  def test_android_upload_internal_uploads_completed_by_default
    in_project do
      ENV.delete('PLAY_RELEASE_STATUS')
      stub_result(:google_play_track_version_codes, [41])
      run_lane(:android, :upload_internal)

      assert_equal 'completed', args_for(:upload_to_play_store)[:release_status]
    end
  end

  def test_android_upload_internal_uploads_a_draft_when_asked
    in_project do
      ENV['PLAY_RELEASE_STATUS'] = 'draft'
      stub_result(:google_play_track_version_codes, [41])
      run_lane(:android, :upload_internal)

      assert_equal 'draft', args_for(:upload_to_play_store)[:release_status]
    end
  end

  def test_android_upload_internal_refuses_a_bad_release_status_before_uploading
    in_project do
      ENV['PLAY_RELEASE_STATUS'] = 'published'
      stub_result(:google_play_track_version_codes, [41])
      assert_raises(UI::UserError) { run_lane(:android, :upload_internal) }

      refute called?(:upload_to_play_store), 'nothing may reach Play with a status the lane does not know'
    end
  end

  def test_android_upload_internal_reads_the_aab_and_mapping_from_the_download_directory
    in_project do |dir|
      assets = File.join(dir, 'workflows-out', 'assets')
      FileUtils.mkdir_p(assets)
      File.write(File.join(assets, 'app-release.aab'), 'aab')
      File.write(File.join(assets, 'mapping.txt'), 'mapping')
      ENV['WORKFLOWS_OUTPUT_DIR'] = File.join(dir, 'workflows-out')
      ENV['WORKFLOWS_ASSETS_DIR'] = assets
      stub_result(:google_play_track_version_codes, [41])
      run_lane(:android, :upload_internal)

      args = args_for(:upload_to_play_store)
      assert_equal File.join(assets, 'app-release.aab'), args[:aab]
      assert_equal File.join(assets, 'mapping.txt'), args[:mapping]
    end
  end

  def test_android_upload_internal_lets_an_explicit_aab_win_over_both_directories
    in_project do |dir|
      ENV['WORKFLOWS_ASSETS_DIR'] = dir
      stub_result(:google_play_track_version_codes, [41])
      run_lane(:android, :upload_internal, aab: '/somewhere/else/app-release.aab')

      assert_equal '/somewhere/else/app-release.aab', args_for(:upload_to_play_store)[:aab]
    end
  end

  # ---------- android promote_beta / release_production ----------

  def test_android_promote_beta_promotes_without_uploading
    in_project do
      run_lane(:android, :promote_beta)

      args = args_for(:upload_to_play_store)
      assert_equal 'internal', args[:track]
      assert_equal 'beta', args[:track_promote_to]
      assert_equal 'completed', args[:track_promote_release_status]
      assert args[:skip_upload_aab]
    end
  end

  def test_android_release_production_promotes_at_the_configured_rollout
    in_project do
      ENV['PLAY_ROLLOUT'] = '0.2'
      ENV['PLAY_UPDATE_PRIORITY'] = '3'
      run_lane(:android, :release_production)

      args = args_for(:upload_to_play_store)
      assert_equal 'beta', args[:track]
      assert_equal 'production', args[:track_promote_to]
      assert_equal '0.2', args[:rollout]
      assert_equal 3, args[:in_app_update_priority]
      refute args[:skip_upload_metadata], 'production is the one lane that syncs the listing'
      refute args[:skip_upload_images]
    end
  end

  def test_android_release_production_defaults_to_a_full_rollout
    in_project do
      run_lane(:android, :release_production)
      assert_equal '1', args_for(:upload_to_play_store)[:rollout]
    end
  end

  # ---------- android sync_metadata ----------

  def test_android_sync_metadata_refuses_when_disabled
    in_project do
      error = assert_raises(UI::UserError) { run_lane(:android, :sync_metadata) }
      assert_includes error.message, 'STORE_METADATA_SYNC_ENABLED'
      refute called?(:upload_to_play_store)
    end
  end

  def test_android_sync_metadata_pushes_metadata_only
    ENV['STORE_METADATA_SYNC_ENABLED'] = 'true'
    in_project do
      File.write('fastlane/metadata/android/en-US/title.txt', 'App')
      FileUtils.mkdir_p('fastlane/metadata/android/en-US/changelogs')
      File.write('fastlane/metadata/android/en-US/changelogs/42.txt', 'notes')
      stub_result(:google_play_track_version_codes, [41, 42])
      run_lane(:android, :sync_metadata)

      args = args_for(:upload_to_play_store)
      assert args[:skip_upload_aab]
      assert args[:skip_upload_apk]
      assert args[:skip_upload_changelogs], "what's new belongs to release_production"
      refute args[:skip_upload_metadata]
      refute args[:skip_upload_images]
      refute args[:skip_upload_screenshots]
      refute args.key?(:track_promote_to)
      refute args.key?(:rollout)
      refute args.key?(:in_app_update_priority)
      assert_equal 'production', args[:track]
      assert_equal 42, args[:version_code]

      snapshot = $metadata_snapshots.last
      assert_includes snapshot, 'en-US/title.txt'
      refute snapshot.any? { |f| f.start_with?('en-US/changelogs') }
    end
  end

  # ---------- android pull_metadata ----------

  def test_android_pull_metadata_dry_run_logs_and_makes_no_sh_call
    ENV['DRY_RUN'] = '1'
    in_project do
      run_lane(:android, :pull_metadata)
      assert UI.messages.any? { |m| m.include?('[dry-run]') }, UI.messages.inspect
      refute called?(:sh)
    end
  end

  def test_android_pull_metadata_runs_supply_init_into_a_tmpdir_then_reports_the_diff
    in_project do
      run_lane(:android, :pull_metadata)

      sh_calls = $calls.select { |name, _| name == :sh }.map(&:last)
      assert_equal 3, sh_calls.length, sh_calls.inspect

      supply_call = sh_calls[0]
      assert_equal %w[bundle exec fastlane supply init], supply_call[0, 5]
      assert_includes supply_call, '--package_name'
      assert_includes supply_call, 'com.example.app'
      assert_includes supply_call, '--track'
      assert_includes supply_call, 'production'
      assert_includes supply_call, '--metadata_path'
      assert_includes supply_call, '--json_key'
      refute_includes supply_call, android_metadata_path,
                       'supply init skips an existing metadata_path and downloads nothing -- it must be a tmpdir'

      # From the repo root, with an absolute pathspec: a lane's cwd is
      # `fastlane/` and a relative pathspec would match nothing there.
      android = root_path('fastlane', 'metadata', 'android')
      assert File.absolute_path?(android), android
      assert_equal ['git', '-C', repo_root, 'status', '--porcelain', '--', android], sh_calls[1]
      assert_equal ['git', '-C', repo_root, '--no-pager', 'diff', '--stat', '--', android], sh_calls[2]

      refute sh_calls.flatten.any? { |arg| arg.to_s.include?('service_account') }, 'no credential value in any argv'
    end
  end

  # ---------- sync_metadata under DRY_RUN ----------

  def test_sync_metadata_dry_run_does_not_upload_or_touch_the_working_tree
    ENV['STORE_METADATA_SYNC_ENABLED'] = 'true'
    ENV['DRY_RUN'] = '1'
    in_project do
      before = Dir.glob('fastlane/metadata/**/*').sort
      run_lane(:ios, :sync_metadata)
      run_lane(:android, :sync_metadata)
      after = Dir.glob('fastlane/metadata/**/*').sort

      refute called?(:upload_to_app_store)
      refute called?(:upload_to_play_store)
      assert UI.messages.any? { |m| m.include?('[dry-run]') }, UI.messages.inspect
      assert_equal before, after
    end
  end

  # ---------- android rollout ----------

  def test_android_rollout_updates_the_fraction_without_uploading
    in_project do
      run_lane(:android, :rollout, percent: 50)

      args = args_for(:upload_to_play_store)
      assert_equal '0.5', args[:rollout]
      assert args[:skip_upload_aab], 'update_rollout is the path with nothing to upload'
      assert args[:skip_upload_apk]
      assert_equal 'production', args[:track]
    end
  end

  # ---------- android halt ----------

  def test_android_halt_sets_the_release_status_through_supply
    in_project do
      run_lane(:android, :halt)

      assert_equal 'halted', args_for(:upload_to_play_store)[:release_status]
      refute called?(:supply_client), 'the fallback is only for when supply fails'
    end
  end

  def test_android_halt_falls_back_to_the_android_publisher_api
    in_project do
      # fastlane #21253/#21431: `release_status: halted` through supply has
      # regressed before, and halting cannot wait for an upstream fix.
      original = Object.instance_method(:upload_to_play_store)
      Object.send(:define_method, :upload_to_play_store) do |**args|
        $calls << [:upload_to_play_store, args]
        raise 'Google Api Error: releases[0].status'
      end
      begin
        run_lane(:android, :halt)
      ensure
        Object.send(:define_method, :upload_to_play_store, original)
      end

      assert called?(:supply_client), 'the direct AndroidPublisher edit must run'
      assert_equal ['halted'], args_for(:supply_update_track)[:statuses]
      assert called?(:supply_commit), 'an uncommitted edit changes nothing'
    end
  end

  def test_android_halt_fallback_refuses_a_version_code_it_cannot_find
    in_project do
      stub_result(:supply_tracks, [Supply::Track.new([Supply::Release.new([7])])])
      original = Object.instance_method(:upload_to_play_store)
      Object.send(:define_method, :upload_to_play_store) { |**_args| raise 'boom' }
      begin
        error = assert_raises(UI::UserError) { run_lane(:android, :halt) }
        assert_includes error.message, '42'
      ensure
        Object.send(:define_method, :upload_to_play_store, original)
      end
    end
  end

  # ---------- android build helpers ----------

  def test_android_signing_properties_carry_the_names_the_config_plugin_reads
    ENV['ANDROID_UPLOAD_KEYSTORE_PATH'] = 'keys/upload.jks'
    ENV['ANDROID_UPLOAD_KEYSTORE_PASSWORD'] = 'store'
    ENV['ANDROID_UPLOAD_KEY_ALIAS'] = 'upload'
    ENV['ANDROID_UPLOAD_KEY_PASSWORD'] = 'key'

    props = android_signing_properties
    # These four names are read by plugins/with-android-release-signing.ts.
    assert_equal %w[ANDROID_UPLOAD_KEY_ALIAS ANDROID_UPLOAD_KEY_PASSWORD ANDROID_UPLOAD_STORE_FILE ANDROID_UPLOAD_STORE_PASSWORD],
                 props.keys.sort
    assert_equal root_path('keys/upload.jks'), props['ANDROID_UPLOAD_STORE_FILE'],
                 'gradle resolves storeFile relative to android/app'
  end

  # gradle is stubbed in these tests, so plant the .aab it would have written -
  # the lane refuses to continue without one, which is why the unsigned branch
  # was never reachable from a unit test before.
  def generated_android_bundle(dir)
    out = File.join(dir, 'android', 'app', 'build', 'outputs', 'bundle', 'release')
    FileUtils.mkdir_p(out)
    File.write(File.join(out, 'app-release.aab'), 'aab')
    # bundletool_command resolves a real binary, which a laptop has from brew
    # and the Checks / Release runner does not - that job installs no Android
    # tooling. Same stub the bundletool_*_args tests use.
    File.write(File.join(dir, 'bundletool'), '#!/bin/sh')
    FileUtils.chmod(0o755, File.join(dir, 'bundletool'))
    ENV['PATH'] = dir
  end

  # The unsigned android build had no coverage at all - no [:android, :build]
  # case existed, signed or unsigned - which is how it shipped producing an
  # APK with no signature. bundletool given no --ks falls back to
  # ~/.android/debug.keystore, which a laptop has and a CI runner does not.
  def test_android_build_signs_the_apk_with_the_projects_debug_keystore
    in_project do |dir|
      generated_android_bundle(dir)
      run_lane(:android, :build, skip_signing: 'true')

      bundletool = $calls.select { |name, _| name == :sh }
                         .map(&:last)
                         .find { |cmd| cmd.is_a?(Array) && cmd.include?('build-apks') }
      refute_nil bundletool, "expected a bundletool build-apks call, got #{$calls.map(&:first).inspect}"

      assert_includes bundletool, "--ks=#{root_path('android/app/debug.keystore')}",
                      'naming the keystore is the fix: without --ks bundletool emits an unsigned APK'
      assert_includes bundletool, '--ks-key-alias=androiddebugkey'
      assert_includes bundletool, '--ks-pass=pass:android'
      assert_includes bundletool, '--key-pass=pass:android'
      refute bundletool.any? { |a| a.to_s.include?('file:') },
             'the debug password is an SDK constant, not a secret needing a password file'
    end
  end

  def test_android_build_unsigned_never_reads_the_upload_keystore
    in_project do |dir|
      generated_android_bundle(dir)
      run_lane(:android, :build, skip_signing: 'true')

      assert_empty args_for(:gradle)[:properties],
                   'the config plugin only falls back when the properties are absent'
      refute called?(:match)
    end
  end

  def test_android_verify_asserts_debug_signing_when_the_build_was_unsigned
    in_project do |dir|
      File.write(File.join(dir, 'verifiers', 'verify-android.sh'), '#!/bin/bash')
      FileUtils.mkdir_p(File.join(dir, 'artifacts', 'android'))
      %w[app-release.aab app-universal.apk].each do |name|
        File.write(File.join(dir, 'artifacts', 'android', name), 'x')
      end

      run_lane(:android, :verify, skip_signing: 'true')
      command = args_for(:sh)
      assert_equal 'bash', command[0]
      assert_includes command, '--expect-debug-signing',
                      'CI passes skip_signing to this lane; it must reach the script'
    end
  end

  def test_android_verify_does_not_assert_debug_signing_for_a_signed_build
    in_project do |dir|
      File.write(File.join(dir, 'verifiers', 'verify-android.sh'), '#!/bin/bash')
      FileUtils.mkdir_p(File.join(dir, 'artifacts', 'android'))
      %w[app-release.aab app-universal.apk].each do |name|
        File.write(File.join(dir, 'artifacts', 'android', name), 'x')
      end

      run_lane(:android, :verify)
      refute_includes args_for(:sh), '--expect-debug-signing'
    end
  end

  def test_android_build_refuses_to_run_without_the_upload_keystore
    in_project do
      error = assert_raises(UI::UserError) { run_lane(:android, :build) }
      assert_includes error.message, 'ANDROID_UPLOAD_KEYSTORE_PATH'
      refute called?(:gradle)
    end
  end

  # The Huawei lane must live
  # under `platform :android`: shared-workflows runs `fastlane <platform>
  # <lane>` and accepts only ios or android, so a top-level lane of the same
  # name would be unreachable from CI and would shadow nothing useful locally.
  def test_upload_huawei_is_not_a_top_level_lane
    error = assert_raises(RuntimeError) { run_lane(nil, :upload_huawei) }
    assert_match(/no lane/, error.message)
  end

  # ---------- Huawei AppGallery ----------

  def test_android_upload_huawei_uploads_the_signed_bundle_and_submits_it
    ENV['HUAWEI_UPLOADS_ENABLED'] = 'true'
    in_project do
      run_lane(:android, :upload_huawei)

      args = args_for(:huawei_appgallery_connect)
      assert_equal root_path('artifacts', 'android', 'app-release.aab'), args[:apk_path]
      assert_equal 'huawei-client', args[:client_id]
      assert_equal 'huawei-secret', args[:client_secret]
      assert_equal '123456789', args[:app_id]
      assert_equal true, args[:is_aab], 'the artifact is an Android App Bundle, not an APK'
      assert_equal true, args[:submit_for_review]
      assert_equal 60, args[:delay_before_submit_for_review]
      assert_equal 'changelog.txt', File.basename(args[:changelog_path].to_s)
      refute_includes args[:changelog_path].to_s, File.join('fastlane', 'metadata'),
                      'the AppGallery changelog is a throwaway temporary file, not tracked metadata'
      refute args.key?(:phase_wise_release), 'a staged AppGallery rollout is out of scope'
      refute args.key?(:release_time), 'the release goes out as soon as review passes'
    end
  end

  def test_android_upload_huawei_asks_for_the_app_record_before_it_uploads
    ENV['HUAWEI_UPLOADS_ENABLED'] = 'true'
    in_project do
      run_lane(:android, :upload_huawei)

      names = $calls.map(&:first)
      assert_operator names.index(:huawei_appgallery_connect_get_app_info), :<,
                      names.index(:huawei_appgallery_connect),
                      "the credential pre-flight must run before any binary moves: #{names.inspect}"
    end
  end

  # The plugin's token helper returns nil on an authentication failure and both
  # actions then only print a message, so a wrong secret would otherwise be a
  # green job that uploaded nothing. get_app_info answers nil when the token is
  # nil, false when the request was refused, and an empty hash when the app
  # record is not visible to this client.
  def test_android_upload_huawei_refuses_when_appgallery_returns_no_app_record
    ENV['HUAWEI_UPLOADS_ENABLED'] = 'true'
    in_project do
      [nil, false, {}].each do |answer|
        UI.reset!
        reset_calls!
        stub_result(:huawei_appgallery_connect_get_app_info, answer)

        error = assert_raises(UI::UserError) { run_lane(:android, :upload_huawei) }
        assert_includes error.message, 'HUAWEI_APP_ID', "answer #{answer.inspect}"
        assert_includes error.message, 'the release runbook'
        refute called?(:huawei_appgallery_connect),
               "a credential pair AppGallery does not accept must not reach the upload (answer #{answer.inspect})"
      end
    end
  end

  # All three tiers go through one lane helper, so both refusals are asserted
  # for each of them rather than for the lane that happened to be written first.
  HUAWEI_LANES = %i[upload_huawei upload_huawei_internal promote_huawei_beta].freeze

  def assert_huawei_lane_refuses_while_the_per_store_toggle_is_off(lane_name)
    in_project do
      error = assert_raises(UI::UserError) { run_lane(:android, lane_name) }
      assert_includes error.message, 'HUAWEI_UPLOADS_ENABLED'
      refute called?(:huawei_appgallery_connect_get_app_info)
      refute called?(:huawei_appgallery_connect)
    end
  end

  def assert_huawei_lane_names_every_missing_credential_variable(lane_name)
    ENV['HUAWEI_UPLOADS_ENABLED'] = 'true'
    ENV.delete('HUAWEI_CLIENT_SECRET')
    ENV['HUAWEI_APP_ID'] = '   '
    in_project do
      error = assert_raises(UI::UserError) { run_lane(:android, lane_name) }
      assert_includes error.message, 'HUAWEI_CLIENT_SECRET'
      assert_includes error.message, 'HUAWEI_APP_ID'
      refute_includes error.message, 'HUAWEI_CLIENT_ID,', 'the variable that is set must not be named'
      refute called?(:huawei_appgallery_connect)
    end
  end

  def test_android_upload_huawei_refuses_while_the_per_store_toggle_is_off
    assert_huawei_lane_refuses_while_the_per_store_toggle_is_off(:upload_huawei)
  end

  def test_android_upload_huawei_internal_refuses_while_the_per_store_toggle_is_off
    assert_huawei_lane_refuses_while_the_per_store_toggle_is_off(:upload_huawei_internal)
  end

  def test_android_promote_huawei_beta_refuses_while_the_per_store_toggle_is_off
    assert_huawei_lane_refuses_while_the_per_store_toggle_is_off(:promote_huawei_beta)
  end

  def test_android_upload_huawei_names_every_missing_credential_variable
    assert_huawei_lane_names_every_missing_credential_variable(:upload_huawei)
  end

  def test_android_upload_huawei_internal_names_every_missing_credential_variable
    assert_huawei_lane_names_every_missing_credential_variable(:upload_huawei_internal)
  end

  def test_android_promote_huawei_beta_names_every_missing_credential_variable
    assert_huawei_lane_names_every_missing_credential_variable(:promote_huawei_beta)
  end

  def test_android_upload_huawei_honours_a_longer_submit_delay
    ENV['HUAWEI_UPLOADS_ENABLED'] = 'true'
    ENV['HUAWEI_SUBMIT_DELAY_SECONDS'] = '180'
    in_project do
      run_lane(:android, :upload_huawei)

      assert_equal 180, args_for(:huawei_appgallery_connect)[:delay_before_submit_for_review]
    end
  end

  def test_android_upload_huawei_refuses_a_submit_delay_that_is_not_a_whole_number
    ENV['HUAWEI_UPLOADS_ENABLED'] = 'true'
    ENV['HUAWEI_SUBMIT_DELAY_SECONDS'] = 'soon'
    in_project do
      error = assert_raises(UI::UserError) { run_lane(:android, :upload_huawei) }
      assert_includes error.message, 'HUAWEI_SUBMIT_DELAY_SECONDS'
      refute called?(:huawei_appgallery_connect)
      # A configuration typo must not cost a real AppGallery call.
      refute called?(:huawei_appgallery_connect_get_app_info)
    end
  end

  def test_android_upload_huawei_uploads_without_a_changelog_when_the_notes_are_too_short
    ENV['HUAWEI_UPLOADS_ENABLED'] = 'true'
    in_project do |dir|
      File.write(File.join(dir, 'store-notes.txt'), 'Fixes.')
      run_lane(:android, :upload_huawei)

      args = args_for(:huawei_appgallery_connect)
      refute args.key?(:changelog_path), 'AppGallery rejects a changelog shorter than 10 characters'
      assert_includes UI.messages.join("\n"), 'below AppGallery'
    end
  end

  # ---------- Huawei AppGallery: the internal and beta test versions ----------

  # AppGallery has one version slot and no tracks, so a tier is a flavour of
  # the submit rather than a destination: these two keys are the whole
  # difference between an internal test version, an open test version and a
  # formal release.
  def test_android_upload_huawei_internal_submits_a_test_version_free_of_manual_review
    ENV['HUAWEI_UPLOADS_ENABLED'] = 'true'
    in_project do
      run_lane(:android, :upload_huawei_internal)

      args = args_for(:huawei_appgallery_connect)
      assert_equal true, args[:use_testing_version]
      assert_equal true, args[:skip_manual_review], 'the internal tier is reviewed automatically, in hours'
      assert_equal root_path('artifacts', 'android', 'app-release.aab'), args[:apk_path]
      assert_equal 'huawei-client', args[:client_id]
      assert_equal 'huawei-secret', args[:client_secret]
      assert_equal '123456789', args[:app_id]
      assert_equal true, args[:is_aab], 'the artifact is an Android App Bundle, not an APK'
      assert_equal true, args[:submit_for_review]
      assert_equal 60, args[:delay_before_submit_for_review]
      assert_equal 'changelog.txt', File.basename(args[:changelog_path].to_s)
      refute args.key?(:phase_wise_release), 'a staged AppGallery rollout is out of scope'
      refute args.key?(:release_time), 'the test version opens when its window starts'
    end
  end

  def test_android_promote_huawei_beta_submits_a_test_version_for_manual_review
    ENV['HUAWEI_UPLOADS_ENABLED'] = 'true'
    in_project do
      run_lane(:android, :promote_huawei_beta)

      args = args_for(:huawei_appgallery_connect)
      assert_equal true, args[:use_testing_version]
      assert_equal false, args[:skip_manual_review], 'open testing goes through AppGallery review'
      assert_equal root_path('artifacts', 'android', 'app-release.aab'), args[:apk_path]
      assert_equal true, args[:is_aab]
      assert_equal true, args[:submit_for_review]
      assert_equal 60, args[:delay_before_submit_for_review]
      assert_equal 'changelog.txt', File.basename(args[:changelog_path].to_s)
      refute args.key?(:phase_wise_release)
      refute args.key?(:release_time)
    end
  end

  def test_android_upload_huawei_submits_no_testing_keys_at_all
    ENV['HUAWEI_UPLOADS_ENABLED'] = 'true'
    ENV['HUAWEI_FEEDBACK_EMAIL'] = 'beta@example.com'
    in_project do
      run_lane(:android, :upload_huawei)

      args = args_for(:huawei_appgallery_connect)
      refute args.key?(:use_testing_version), 'the release tier is the same version slot with testing off'
      refute args.key?(:skip_manual_review)
      refute args.key?(:test_start_time)
      refute args.key?(:test_end_time)
      refute args.key?(:feedback_email), 'the feedback address belongs to a test version'
    end
  end

  def test_the_tester_feedback_address_is_sent_only_once_it_is_configured
    ENV['HUAWEI_UPLOADS_ENABLED'] = 'true'
    in_project do
      run_lane(:android, :upload_huawei_internal)
      refute args_for(:huawei_appgallery_connect).key?(:feedback_email),
             'the plugin puts the key in the request body unconditionally, so an unset address must not be passed'

      reset_calls!
      ENV['HUAWEI_FEEDBACK_EMAIL'] = 'beta@example.com'
      run_lane(:android, :upload_huawei_internal)

      assert_equal 'beta@example.com', args_for(:huawei_appgallery_connect)[:feedback_email]
    end
  end

  # The plugin's own default window formats a *local* time with a hardcoded
  # +0000 suffix, so it is an hour or more wrong off a non-UTC machine. The
  # lane therefore always passes both ends of the window, computed in UTC.
  def test_the_test_window_is_a_utc_pair_the_configured_number_of_days_apart
    ENV['HUAWEI_UPLOADS_ENABLED'] = 'true'
    ENV['HUAWEI_TEST_DAYS'] = '7'
    in_project do
      run_lane(:android, :upload_huawei_internal)

      args = args_for(:huawei_appgallery_connect)
      format = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\+0000\z/
      assert_match format, args[:test_start_time]
      assert_match format, args[:test_end_time]
      start = Time.parse(args[:test_start_time])
      finish = Time.parse(args[:test_end_time])
      assert_equal 7 * 24 * 60 * 60, finish - start
      assert_in_delta Time.now.utc + 3600, start, 120, 'the window opens an hour out, in UTC'
    end
  end

  def test_a_test_window_above_the_appgallery_ceiling_is_clamped_with_a_message
    ENV['HUAWEI_UPLOADS_ENABLED'] = 'true'
    ENV['HUAWEI_TEST_DAYS'] = '365'
    in_project do
      run_lane(:android, :upload_huawei_internal)

      args = args_for(:huawei_appgallery_connect)
      days = (Time.parse(args[:test_end_time]) - Time.parse(args[:test_start_time])) / (24 * 60 * 60)
      assert_equal 89, days
      assert_includes UI.messages.join("\n"), '89'
    end
  end

  def test_a_test_window_that_is_not_a_whole_number_of_days_is_refused
    ENV['HUAWEI_UPLOADS_ENABLED'] = 'true'
    # Zero passes the digits check and fails only the above-zero one.
    ['three weeks', '0'].each do |value|
      reset_calls!
      ENV['HUAWEI_TEST_DAYS'] = value
      in_project do
        error = assert_raises(UI::UserError) { run_lane(:android, :upload_huawei_internal) }
        assert_includes error.message, 'HUAWEI_TEST_DAYS'
        refute called?(:huawei_appgallery_connect)
        # A configuration typo must not cost a real AppGallery call.
        refute called?(:huawei_appgallery_connect_get_app_info)
      end
    end
  end

  # A version under review blocks the next submission on the same app, so a
  # push landing during a beta review skips instead of failing: the review
  # queue belongs to Huawei and must not turn main red for days.
  def test_a_busy_version_slot_skips_the_upload_on_every_tier
    ENV['HUAWEI_UPLOADS_ENABLED'] = 'true'
    records = [3, 4, 5, 12, '4'].map { |state| { 'releaseState' => state } } + [{ releaseState: 4 }]
    in_project do
      HUAWEI_LANES.each do |lane_name|
        records.each do |record|
          UI.reset!
          reset_calls!
          stub_result(:huawei_appgallery_connect_get_app_info, record)

          run_lane(:android, lane_name)
          refute called?(:huawei_appgallery_connect), "#{lane_name} uploaded over #{record.inspect}"
          assert_includes UI.messages.join("\n"), 'skipping the upload', "#{lane_name} over #{record.inspect}"
        end
      end
    end
  end

  # Fail-open: whether a *testing* submission moves the app record into a busy
  # state at all is unverified, so every state the lane does not recognise --
  # and a record without the field, which is what the canned dry-run answer is
  # -- takes the upload path.
  def test_an_unrecognised_release_state_still_uploads_on_every_tier
    ENV['HUAWEI_UPLOADS_ENABLED'] = 'true'
    in_project do
      HUAWEI_LANES.each do |lane_name|
        [nil, 0, 7, 99, 'unknown'].each do |state|
          UI.reset!
          reset_calls!
          stub_result(:huawei_appgallery_connect_get_app_info, { 'appName' => 'Stub', 'releaseState' => state })

          run_lane(:android, lane_name)
          assert called?(:huawei_appgallery_connect),
                 "#{lane_name} withheld the upload over releaseState #{state.inspect}"
        end
      end
    end
  end

  # ---------- the package Fastfile, loaded by real fastlane ----------

  # An app's whole Fastfile is one relative import of the package's, from where
  # the package is installed. fastlane resolves a relative import against the
  # Fastfile it started from, so a nested relative import inside the package
  # would be looked up in the app: this is the check that the lanes arrive.
  def test_an_app_that_imports_the_package_fastfile_gets_every_lane_under_real_fastlane
    package = File.expand_path('../..', __dir__)
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, 'node_modules', '@blinkbitcoin'))
      File.symlink(package, File.join(dir, 'node_modules', '@blinkbitcoin', 'app-tooling'))
      FileUtils.mkdir_p(File.join(dir, 'fastlane'))
      File.write(File.join(dir, 'fastlane', 'Fastfile'),
                 "import '../node_modules/@blinkbitcoin/app-tooling/fastlane/Fastfile'\n")
      # fastlane reads the Fastfile in the locale's encoding, and the lanes' comments
      # and messages are not ASCII; a runner has a UTF-8 locale, a bare shell may not.
      env = { 'FASTLANE_SKIP_ENV_ASSERT' => '1', 'FASTLANE_SKIP_UPDATE_CHECK' => '1', 'FASTLANE_HIDE_CHANGELOG' => '1', 'CI' => '1',
              'LANG' => 'en_US.UTF-8', 'LC_ALL' => 'en_US.UTF-8' }
      output = IO.popen(env, [RbConfig.ruby, '-S', 'bundle', 'exec', 'fastlane', 'lanes'], chdir: dir, err: %i[child out], &:read)
      assert $CHILD_STATUS.success?, output
      %w[ios:build ios:verify ios:upload_internal ios:promote_beta ios:release_production ios:phased ios:upload_symbols
         android:build android:verify android:upload_internal android:promote_beta android:release_production
         android:rollout android:halt android:upload_huawei].each do |lane|
        platform, lane_name = lane.split(':')
        assert_includes output, "fastlane #{platform} #{lane_name}", "fastlane does not list #{lane}:\n#{output}"
      end
    end
  end

  # ---------- arguments vs. the real fastlane action definitions ----------

  # Replays every recorded action call through the real option set. The stubs
  # accept any key of any type, so without this the suite is thorough about
  # *which* arguments a lane passes and silent about whether fastlane will take
  # them -- which is how a Float `rollout` shipped green past 73 tests and a
  # clean six-lane dry run, then aborted on the first real invocation.
  #
  # The validator runs in a child process: loading the fastlane gem here would
  # pull in the real `supply` (through UploadToPlayStoreAction.available_options)
  # and replace the supply double the `halt` fallback test depends on.
  def validate_fastlane_options(recorded)
    script = File.expand_path('validate_options.rb', __dir__)
    output = nil
    IO.popen([RbConfig.ruby, script], 'r+') do |io|
      io.write(JSON.generate(recorded))
      io.close_write
      output = io.read
    end
    return ["validator exited #{$CHILD_STATUS.exitstatus}: #{output}"] unless $CHILD_STATUS.success?

    # fastlane can chatter on stdout; the result is the last line.
    JSON.parse(output.to_s.lines.map(&:strip).reject(&:empty?).last.to_s)
  end

  def test_every_lane_argument_hash_is_accepted_by_the_real_fastlane_action
    recorded = []
    in_project(notes: { 'en-US' => { 'appstore' => 'Notes.', 'play' => 'Notes.' } }) do |dir|
      generated_ios_project(dir)
      File.write(File.join(dir, 'artifacts', 'android', 'mapping.txt'), 'mapping')
      ENV['MATCH_GIT_URL'] = 'git@example.com:certs.git'
      ENV['MATCH_PASSWORD'] = 'secret'
      ENV['APP_REVIEW_EMAIL'] = 'review@example.com'
      ENV['APP_REVIEW_DEMO_USER'] = 'demo'
      ENV['APP_REVIEW_DEMO_PASSWORD'] = 'demopass'
      ENV['PLAY_UPDATE_PRIORITY'] = '3'
      ENV['STORE_METADATA_SYNC_ENABLED'] = 'true'
      ENV['HUAWEI_UPLOADS_ENABLED'] = 'true'
      ENV['HUAWEI_FEEDBACK_EMAIL'] = 'beta@example.com'
      # So sync_metadata records app_rating_config_path and screenshots_path
      # too: both are conditional on the file/PNG existing, and neither
      # option name is validated against the real action otherwise.
      File.write(File.join(dir, 'fastlane', 'metadata', 'ios', 'app_rating_config.json'), '{}')
      FileUtils.mkdir_p(File.join(dir, 'fastlane', 'screenshots', 'en-US'))
      File.write(File.join(dir, 'fastlane', 'screenshots', 'en-US', '01.png'), 'x')

      [
        [:ios, :build, { skip_signing: 'true' }],
        [:ios, :build, {}],
        [:ios, :upload_internal, {}],
        [:ios, :promote_beta, {}],
        [:ios, :release_production, {}],
        [:ios, :sync_metadata, {}],
        [:ios, :sync_metadata, { live: 'true' }],
        [:ios, :phased, { action: 'pause' }],
        [:ios, :upload_symbols, {}],
        [:android, :upload_internal, {}],
        [:android, :promote_beta, {}],
        [:android, :release_production, {}],
        [:android, :sync_metadata, {}],
        [:android, :rollout, { percent: 50 }],
        [:android, :halt, {}],
        # changelog_path is a plain String option with no verify block, so the
        # temporary file the lane wrote is allowed to be gone by validation time
        # (unlike deliver's app_rating_config_path below).
        [:android, :upload_huawei, {}],
        # The five testing options are reverse-engineered from the console, so
        # the replay checking their names against the real plugin matters more
        # here than anywhere else.
        [:android, :upload_huawei_internal, {}],
        [:android, :promote_huawei_beta, {}]
      ].each do |platform_name, lane_name, options|
        reset_calls!
        stub_result(:latest_testflight_build_number, 41)
        stub_result(:google_play_track_version_codes, [41])
        run_lane(platform_name, lane_name, options)
        $calls.each do |action, args|
          next unless STUBBED_FASTLANE_ACTIONS.include?(action)

          if args.key?(:app_rating_config_path)
            # deliver's app_rating_config_path option verifies the file exists
            # at validation time (deliver/lib/deliver/options.rb:270), but the
            # staged copy sync_metadata actually passed is deleted the moment
            # the lane returns. The source file it was copied from has the
            # same content and outlives this whole test, so swap it in here --
            # this still validates the option name and a real JSON file, just
            # not the exact (necessarily transient) path.
            args = args.merge(app_rating_config_path: File.join(dir, 'fastlane', 'metadata', 'ios', 'app_rating_config.json'))
          end
          recorded << { action: action.to_s, args: args, lane: "#{platform_name} #{lane_name}" }
        end
      end

      refute_empty recorded
      errors = validate_fastlane_options(recorded)
      assert_empty errors, "fastlane rejects these lane arguments:\n#{errors.join("\n")}"
    end
  end

  # fastlane reads the Fastfile and every lane file with the process's default
  # external encoding and evals the string. On a machine whose locale is not
  # UTF-8 (a laptop with LANG unset, a minimal container) that is US-ASCII, and
  # a single non-ASCII character, even inside a message or a comment, stops
  # `fastlane lanes` with "invalid multibyte char (US-ASCII)". CI runners are
  # UTF-8, so only a local run or a stripped-down image would find out.
  def test_every_file_fastlane_loads_is_ascii_only
    root = File.expand_path('..', __dir__)
    files = [File.join(root, 'Fastfile')] + Dir.glob(File.join(root, 'lanes', '*.rb'))
    refute_empty files
    offenders = files.flat_map do |file|
      File.binread(file).each_line.with_index(1).filter_map do |line, number|
        "#{file.delete_prefix("#{root}/")}:#{number}" unless line.ascii_only?
      end
    end
    assert_empty offenders, "non-ASCII characters break `fastlane lanes` without a UTF-8 locale:\n#{offenders.join("\n")}"
  end
end
