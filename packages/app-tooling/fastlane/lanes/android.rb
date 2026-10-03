# Android lanes (bundle, internal track, staged production rollout).
#
# Everything that uploads or promotes goes through `store_action` from
# shared.rb, so DRY_RUN=1 walks a whole release without touching a store.
#
# Play metadata lives in fastlane/metadata/android/, which is supply's default.
# Play's "What's new" cap, counted in characters (see store-notes.prompt.md).
PLAY_NOTES_LIMIT = 500
# arm only: Play has not accepted x86 for phones in years, and dropping the
# other ABIs roughly halves the AAB and the build time.
ANDROID_ABIS = 'armeabi-v7a,arm64-v8a'.freeze
ANDROID_UPLOAD_KEYSTORE_ENV = %w[
  ANDROID_UPLOAD_KEYSTORE_PATH ANDROID_UPLOAD_KEYSTORE_PASSWORD
  ANDROID_UPLOAD_KEY_ALIAS ANDROID_UPLOAD_KEY_PASSWORD
].freeze

# gradle resolves `storeFile` relative to android/app, and fastlane runs lanes
# from fastlane/, so the keystore path is made absolute from the repo root
# before it goes anywhere near either.
def android_keystore_path
  path = ENV.fetch('ANDROID_UPLOAD_KEYSTORE_PATH')
  File.absolute_path?(path) ? path : root_path(path)
end

# The gradle properties the app's release signing config reads. An Expo app gets
# that config from a config plugin at prebuild (the template's
# `with-android-release-signing`); a bare app writes the same four names into its
# app/build.gradle (docs/consumer-guide.md, "The lanes"). Passing them as properties rather than writing gradle.properties keeps the
# keystore password out of the generated project and out of any build log.
def android_signing_properties
  {
    'ANDROID_UPLOAD_STORE_FILE' => android_keystore_path,
    'ANDROID_UPLOAD_STORE_PASSWORD' => ENV.fetch('ANDROID_UPLOAD_KEYSTORE_PASSWORD'),
    'ANDROID_UPLOAD_KEY_ALIAS' => ENV.fetch('ANDROID_UPLOAD_KEY_ALIAS'),
    'ANDROID_UPLOAD_KEY_PASSWORD' => ENV.fetch('ANDROID_UPLOAD_KEY_PASSWORD')
  }
end

# The bundletool `build-apks` arguments, minus the signing flags.
#
# Split out from the lane so the signed and unsigned forms can be unit-tested:
# the difference between them is four arguments, two of which are password file
# paths, and getting that branch wrong either leaks a credential into the
# process table or silently produces an APK signed with the wrong key.
def bundletool_build_apks_args(bundle, output)
  [
    *bundletool_command,
    'build-apks',
    "--bundle=#{bundle}",
    "--output=#{output}",
    '--mode=universal'
  ]
end

# The four signing arguments for the upload keystore, given the two password
# files. The unsigned build uses bundletool_debug_signing_args instead - never
# no arguments at all, see there for why.
def bundletool_signing_args(store_pass_file, key_pass_file)
  [
    "--ks=#{android_keystore_path}",
    "--ks-pass=file:#{store_pass_file}",
    "--ks-key-alias=#{ENV.fetch('ANDROID_UPLOAD_KEY_ALIAS')}",
    "--key-pass=file:#{key_pass_file}"
  ]
end

# The same four arguments for the debug keystore `expo prebuild` ships at
# android/app/debug.keystore - the one the release build type already falls back
# to when the ANDROID_UPLOAD_* properties are absent
# (plugins/with-android-release-signing.ts). So the universal APK carries the
# same signature as the bundle it was derived from.
#
# Naming it is the point. Given no --ks at all, bundletool falls back to
# ~/.android/debug.keystore, which Android Studio, adb or an emulator launch
# creates - so a developer machine has one and a fresh CI runner does not. When
# it is missing bundletool emits an *unsigned* APK and says nothing, and the
# first thing to notice was `apksigner verify` failing in CI with
# "Missing META-INF/MANIFEST.MF" on a build that passed on every laptop.
#
# The passwords are inline rather than in 0600 files like the signed branch:
# `android` is the Android SDK's published constant for the debug keystore, not
# a credential, and hiding it would imply otherwise.
def bundletool_debug_signing_args
  [
    "--ks=#{root_path('android/app/debug.keystore')}",
    '--ks-pass=pass:android',
    '--ks-key-alias=androiddebugkey',
    '--key-pass=pass:android'
  ]
end

# Writes each secret to its own 0600 file for the duration of the block, so a
# password reaches bundletool without ever appearing in an argument list.
def with_password_files(*secrets)
  require 'tempfile'
  files = secrets.map do |secret|
    file = Tempfile.new('app-pass')
    file.chmod(0o600)
    file.write(secret) # no trailing newline: bundletool reads the file verbatim
    file.close
    file
  end
  yield(*files.map(&:path))
ensure
  files&.each { |file| file.close! }
end

# The single universal.apk inside the .apks archive bundletool just wrote.
def extract_universal_apk!(apks_path, destination)
  require 'zip'
  require 'fileutils'
  Zip::File.open(apks_path) do |archive|
    entry = archive.find_entry('universal.apk')
    UI.user_error!("bundletool produced no universal.apk in #{apks_path}") if entry.nil?
    FileUtils.rm_f(destination)
    # Streamed out rather than `entry.extract(destination)`: rubyzip 3 resolves
    # that path against its own destination_directory, which put the file under
    # a doubled absolute path, while rubyzip 2 (what fastlane 2.239 locks) took it
    # as given. Writing the bytes ourselves means the same on both.
    entry.get_input_stream { |stream| File.binwrite(destination, stream.read) }
  end
  destination
end

def android_aab_path
  Dir.glob(root_path('android', 'app', 'build', 'outputs', 'bundle', 'release', '*.aab')).sort.first
end

def android_mapping_path
  path = root_path('android', 'app', 'build', 'outputs', 'mapping', 'release', 'mapping.txt')
  File.exist?(path) ? path : nil
end

# The Play release status of a new internal upload. `completed` publishes it to
# the internal testers; a Play app that has never been published only accepts
# `draft`, so PLAY_RELEASE_STATUS=draft is the setting until the first release.
# Unset means `completed`.
def play_release_status
  status = ENV['PLAY_RELEASE_STATUS'].to_s.strip
  status = 'completed' if status.empty?
  UI.user_error!("PLAY_RELEASE_STATUS must be completed or draft (got #{status.inspect})") unless %w[completed draft].include?(status)

  status
end

platform :android do
  desc 'Build the release AAB and a universal APK from that same bundle'
  lane :build do |options|
    # Without a keystore this still builds: the app's signing config falls back
    # to the debug keystore when the ANDROID_UPLOAD_* gradle properties are
    # absent (the template's plugin does, and warns that it did). So a repository with no Play
    # credentials still compiles, still produces an .aab, a universal .apk and a
    # mapping file, and still runs `verify` - it simply cannot upload any of it.
    # Mirrors `skip_signing` on the iOS lane so the two read the same way.
    skip_signing = truthy?(options[:skip_signing])
    require_env!(ANDROID_UPLOAD_KEYSTORE_ENV) unless skip_signing
    out = prepare_output_dir!(output_dir('android'))

    gradle(
      project_dir: root_path('android'),
      task: 'bundle',
      build_type: 'Release',
      flags: "-PreactNativeArchitectures=#{ANDROID_ABIS}",
      # No properties at all when skipping: the plugin's fallback only applies
      # when the properties are absent, so passing empty ones would defeat it.
      properties: skip_signing ? {} : android_signing_properties,
      # The signing properties are on the command line: printing it would put
      # the keystore password in the build log.
      print_command: false
    )

    aab = android_aab_path
    UI.user_error!('gradle bundleRelease produced no .aab under android/app/build/outputs/bundle/release') if aab.nil?

    require 'fileutils'
    FileUtils.cp(aab, File.join(out, 'app-release.aab'))
    mapping = android_mapping_path
    FileUtils.cp(mapping, File.join(out, 'mapping.txt')) if mapping

    # The universal APK comes out of the same bundle that Play will receive, so
    # what QA installs is the artifact being released, not a second build of it.
    apks = File.join(out, 'app-universal.apks')
    FileUtils.rm_f(apks)
    # `--ks-pass=pass:` would put the keystore password in the process table,
    # where `log: false` cannot reach it; bundletool's `file:` form reads it
    # from a 0600 file that exists only for the length of the call.
    build_apks = bundletool_build_apks_args(File.join(out, 'app-release.aab'), apks)
    if skip_signing
      # The bundle gradle just produced is debug-signed, so sign the APK with
      # that same keystore. Installable for a smoke test, and recognisably not a
      # release artifact - the debug certificate is what says so.
      sh(*build_apks, *bundletool_debug_signing_args, log: false)
    else
      with_password_files(
        ENV.fetch('ANDROID_UPLOAD_KEYSTORE_PASSWORD'),
        ENV.fetch('ANDROID_UPLOAD_KEY_PASSWORD')
      ) do |store_pass_file, key_pass_file|
        sh(*build_apks, *bundletool_signing_args(store_pass_file, key_pass_file), log: false)
      end
    end
    # build-apks writes a zip; the universal APK is the single entry inside it.
    # rubyzip comes with fastlane, so this needs no `unzip` on the runner.
    apk = extract_universal_apk!(apks, File.join(out, 'app-universal.apk'))
    FileUtils.rm_f(apks)

    # The provenance record of what this build actually produced. verify-android's
    # `apk-sha` check compares the APK it is handed against `artifacts.apkSha256`,
    # which is what catches a universal APK built from a different bundle than the
    # one being uploaded.
    written = write_build_info_artifacts!(
      out,
      aabSha256: file_sha256(File.join(out, 'app-release.aab')),
      apkSha256: file_sha256(apk)
    )
    UI.message("Artifact checksums recorded in #{written}") if written
  end

  desc 'Run the Android artifact verification gate'
  lane :verify do |options|
    script = verify_script!('verify-android.sh')
    out = output_dir('android')
    aab = options[:aab] || File.join(out, 'app-release.aab')
    apk = options[:apk] || File.join(out, 'app-universal.apk')
    [aab, apk].each do |path|
      UI.user_error!("Nothing to verify at #{path} - run `fastlane android build` first") unless File.exist?(path)
    end

    # Mirrors ios.rb's --no-signing forwarding, with the opposite meaning: iOS
    # skips its signing checks because an unsigned archive has nothing to check,
    # while an unsigned Android build still produces a debug-signed APK, so this
    # asserts that identity. CI already passes skip_signing to this lane
    # (shared-workflows' build-android.yml); until now it was ignored.
    args = ['bash', script, aab, apk]
    args << '--expect-debug-signing' if truthy?(options[:skip_signing])

    run_verifier(*args)
  end

  desc 'Upload the AAB to the internal track (idempotent)'
  lane :upload_internal do |options|
    build_info # asserts the artifact belongs to this version/build number
    package = ENV.fetch('ANDROID_PACKAGE')
    version_code = ENV.fetch('APP_BUILD_NUMBER')
    # artifact_dir, not output_dir: this job downloaded the build job's
    # artifacts into $WORKFLOWS_ASSETS_DIR and has nothing of its own to upload.
    out = artifact_dir('android')

    # Play rejects a duplicate version code outright, which turns any retry of
    # the release job into a red build. Ask first.
    existing = store_action(
      :google_play_track_version_codes,
      package_name: package,
      track: 'internal',
      **play_json_key_args
    )
    if Array(existing).map(&:to_s).include?(version_code.to_s)
      UI.important("Play internal track already has version code #{version_code} - skipping upload")
      next
    end

    # supply reads the changelog for a version code from the metadata tree, so
    # the notes have to be on disk before the upload rather than passed to it.
    written = write_release_notes!(
      android_metadata_path,
      kind: :play,
      limit: PLAY_NOTES_LIMIT,
      changelog_name: "#{version_code}.txt"
    )
    UI.message("Changelogs written: #{written.join(', ')}")

    args = {
      package_name: package,
      track: 'internal',
      release_status: play_release_status,
      aab: options[:aab] || File.join(out, 'app-release.aab'),
      metadata_path: android_metadata_path,
      # Store listing and images are synced once, from release_production;
      # an internal upload must not be able to change what the public sees.
      skip_upload_metadata: true,
      skip_upload_images: true,
      skip_upload_screenshots: true,
      skip_upload_changelogs: false,
      version_code: version_code.to_i,
      version_name: ENV.fetch('APP_VERSION'),
      **play_json_key_args
    }
    mapping = File.join(out, 'mapping.txt')
    args[:mapping] = mapping if File.exist?(mapping)

    store_action(:upload_to_play_store, **args)
  end

  desc 'Promote the internal build to the open beta track'
  lane :promote_beta do
    store_action(
      :upload_to_play_store,
      package_name: ENV.fetch('ANDROID_PACKAGE'),
      track: 'internal',
      track_promote_to: 'beta',
      track_promote_release_status: 'completed',
      version_code: ENV.fetch('APP_BUILD_NUMBER').to_i,
      # Nothing is uploaded: this promotes the version code that is already there.
      skip_upload_aab: true,
      skip_upload_apk: true,
      skip_upload_metadata: true,
      skip_upload_changelogs: true,
      skip_upload_images: true,
      skip_upload_screenshots: true,
      **play_json_key_args
    )
  end

  desc 'Promote the beta build to production at PLAY_ROLLOUT, syncing the full store listing'
  lane :release_production do
    assert_metadata_ready!(android_metadata_path)
    version_code = ENV.fetch('APP_BUILD_NUMBER')
    written = write_release_notes!(
      android_metadata_path,
      kind: :play,
      limit: PLAY_NOTES_LIMIT,
      changelog_name: "#{version_code}.txt"
    )
    UI.message("Changelogs written: #{written.join(', ')}")

    args = {
      package_name: ENV.fetch('ANDROID_PACKAGE'),
      track: 'beta',
      track_promote_to: 'production',
      rollout: play_rollout,
      version_code: version_code.to_i,
      skip_upload_aab: true,
      skip_upload_apk: true,
      # The one lane that syncs the public listing, so a change to the store
      # page can only ever ship as part of a production release.
      metadata_path: android_metadata_path,
      skip_upload_metadata: false,
      skip_upload_changelogs: false,
      skip_upload_images: false,
      skip_upload_screenshots: false,
      **play_json_key_args
    }
    priority = ENV['PLAY_UPDATE_PRIORITY'].to_s.strip
    args[:in_app_update_priority] = priority.to_i unless priority.empty?

    store_action(:upload_to_play_store, **args)
  end

  desc 'Push the baseline store listing from fastlane/metadata/android to Google Play (no binary, no track change, no changelogs)'
  lane :sync_metadata do
    assert_metadata_sync_enabled!
    source = android_metadata_path
    assert_metadata_locales!(source)
    assert_metadata_ready!(source)
    package = ENV.fetch('ANDROID_PACKAGE')
    track, version_code = play_metadata_target
    UI.message("Syncing the Play listing against #{track} version code #{version_code}")

    with_baseline_metadata(source) do |staged|
      store_action(
        :upload_to_play_store,
        package_name: package,
        # The track and version code that are already there, so supply can
        # find the release its listing edit hangs off. Nothing moves: no
        # binary is uploaded, and with no track_promote_to and no rollout
        # supply never touches the track itself (uploader.rb:29-42).
        track: track,
        version_code: version_code,
        skip_upload_aab: true,
        skip_upload_apk: true,
        metadata_path: staged,
        skip_upload_metadata: false,
        skip_upload_images: false,
        skip_upload_screenshots: false,
        # "What's new" is per version and belongs to release_production's
        # write_release_notes!; the staged tree has no changelogs/ either, so
        # this is belt and braces on purpose.
        skip_upload_changelogs: true,
        **play_json_key_args
      )
    end
  end

  desc 'Pull the Play listing, images and screenshots into the repo (overwrites local files - review the diff)'
  lane :pull_metadata do
    warn_metadata_overwrite!('fastlane/metadata/android')
    package = ENV.fetch('ANDROID_PACKAGE')
    track = ENV['PLAY_METADATA_TRACK'].to_s.strip
    track = 'production' if track.empty?

    if ENV['DRY_RUN'] == '1'
      UI.important("[dry-run] supply init for #{package} (#{track}) into #{android_metadata_path}")
      next
    end

    require 'tmpdir'
    require 'fileutils'
    # `supply init` does something worse than refuse an existing
    # metadata_path: it prints "Metadata already exists" and returns having
    # downloaded nothing, exit 0 (supply/lib/supply/setup.rb:6-9). Every
    # checkout of this template has that directory, so a pull straight into
    # the tree would report success and change nothing. Hence the staging
    # directory, from which the tree is updated file by file - a local file
    # supply does not know about (a locale it has never seen) is left alone.
    Dir.mktmpdir('play-metadata-pull') do |dir|
      staged = File.join(dir, 'android')
      with_play_json_key_file do |key_path|
        sh('bundle', 'exec', 'fastlane', 'supply', 'init',
           '--package_name', package, '--track', track,
           '--metadata_path', staged, '--json_key', key_path)
      end
      FileUtils.cp_r(Dir.glob(File.join(staged, '*')), android_metadata_path)
    end

    # shared.rb cannot call `sh` itself (see its header) - it only builds the
    # argv, and it is run here. Absolute paths: the lane's cwd is `fastlane/`,
    # not the repo root (see metadata_diff_commands).
    metadata_diff_commands(android_metadata_path).each { |argv| sh(*argv) }
  end

  desc 'Change the production staged-rollout share. Whole number = percent (percent:1 is 1%, percent:100 completes); a decimal is a fraction (percent:0.01 is 1%, percent:1.0 completes)'
  lane :rollout do |options|
    fraction = rollout_fraction(options[:percent] || ENV['PLAY_ROLLOUT'])
    UI.important("Setting the production rollout to #{(fraction.to_f * 100).round(4)}% of users")

    store_action(
      :upload_to_play_store,
      package_name: ENV.fetch('ANDROID_PACKAGE'),
      track: 'production',
      rollout: fraction,
      version_code: ENV.fetch('APP_BUILD_NUMBER').to_i,
      # With nothing to upload and a track + rollout set, supply takes the
      # update_rollout path; 1.0 completes the rollout.
      skip_upload_aab: true,
      skip_upload_apk: true,
      skip_upload_metadata: true,
      skip_upload_changelogs: true,
      skip_upload_images: true,
      skip_upload_screenshots: true,
      **play_json_key_args
    )
  end

  desc 'Halt the production rollout'
  lane :halt do
    package = ENV.fetch('ANDROID_PACKAGE')
    version_code = ENV.fetch('APP_BUILD_NUMBER').to_i
    # Outside the begin: a missing credential is not a supply regression, and
    # reporting it as one would send the operator to the wrong fix.
    credentials = play_json_key_args

    begin
      store_action(
        :upload_to_play_store,
        package_name: package,
        track: 'production',
        release_status: 'halted',
        version_code: version_code,
        skip_upload_aab: true,
        skip_upload_apk: true,
        skip_upload_metadata: true,
        skip_upload_changelogs: true,
        skip_upload_images: true,
        skip_upload_screenshots: true,
        **credentials
      )
    rescue StandardError => e
      # `release_status: halted` through supply has regressed more than once
      # (fastlane #21253, #21431). Halting a bad rollout is the one operation
      # that cannot wait for an upstream fix, so go at the API directly.
      UI.important("supply could not halt the rollout (#{e.message}); falling back to the AndroidPublisher API")
      halt_via_android_publisher!(package, version_code)
    end
  end
end

# PLAY_ROLLOUT is a fraction supply understands; the production workflow's
# dispatch input collects a percentage. Default: the whole user base.
def play_rollout
  raw = ENV['PLAY_ROLLOUT'].to_s.strip
  rollout_fraction(raw.empty? ? '1.0' : raw)
end

# The *form* of the input decides what it means, not its magnitude. `1` is both
# the first step of a canary (1%) and the fraction for everybody, and resolving
# that collision by size would silently ship a 1% canary to 100% of users. So:
#
#   whole number  -> percent    "1" -> 0.01, "50" -> 0.5, "100" -> 1
#   has a decimal -> fraction   "0.01" -> 0.01, "0.5" -> 0.5, "1.0" -> 1
#
# Anything outside 0 < x <= 1 after that conversion is a mistake, not a reading
# to guess at, so `1.5` and `150` both fail rather than being clamped.
#
# The result is a String because supply's `rollout` ConfigItem is `data_type:
# String` and FastlaneCore rejects a Float before the action ever runs.
def rollout_fraction(value)
  raw = value.to_s.strip
  begin
    number = Float(raw)
  rescue ArgumentError, TypeError
    UI.user_error!("Rollout must be a number (got #{value.inspect})")
  end
  number /= 100.0 unless raw.include?('.')
  # supply rejects 0 (`must be greater than 0.0 and less than or equal to 1.0`);
  # stopping a rollout is what `halt` is for.
  unless number > 0.0 && number <= 1.0
    UI.user_error!("Rollout #{value.inspect} is out of range: use a whole number of percent (1..100) or a fraction (0.01..1.0)")
  end

  format('%g', number)
end

# The direct AndroidPublisher edit supply's `release_status: halted` is supposed
# to perform: open an edit, set every release in the production track that
# carries this version code to `halted`, commit.
def halt_via_android_publisher!(package, version_code)
  # supply is already loaded inside a real fastlane run (upload_to_play_store
  # pulls it in); the guard is what lets the unit tests substitute it.
  require 'supply' unless defined?(Supply)

  Supply.config = FastlaneCore::Configuration.create(
    Supply::Options.available_options,
    { package_name: package, track: 'production' }.merge(play_json_key_args)
  )
  client = Supply::Client.make_from_config
  client.begin_edit(package_name: package)
  track = client.tracks(Supply::Tracks::PRODUCTION).first
  UI.user_error!('No production track to halt') if track.nil?

  halted = track.releases.select { |release| Array(release.version_codes).map(&:to_s).include?(version_code.to_s) }
  UI.user_error!("No production release for version code #{version_code}") if halted.empty?
  halted.each { |release| release.status = Supply::ReleaseStatus::HALTED }

  client.update_track(Supply::Tracks::PRODUCTION, track)
  client.commit_current_edit!
  UI.success("Halted the production rollout of version code #{version_code}")
end
