# iOS lanes (build, TestFlight, App Store submission).
#
# Everything that uploads or promotes goes through `store_action` from
# shared.rb, so DRY_RUN=1 walks a whole release without touching a store.
#
# App Store metadata lives in fastlane/metadata/ios/ rather than deliver's
# default fastlane/metadata/, so that supply's fastlane/metadata/android/ is not
# mistaken for an App Store locale. Lanes pass `metadata_path: ios_metadata_path`.
#
# Lanes must also pass `app_review_information: review_information` (the helper
# in shared.rb): the files under metadata/ios/review_information/ are blank on
# purpose, and deliver would otherwise upload those blanks and clear the App
# Review contact, demo account and notes.
# App Store Connect's own caps, counted in characters (see store-notes.prompt.md).
TESTFLIGHT_NOTES_LIMIT = 4000
APP_STORE_NOTES_LIMIT = 4000

# The .ipa when there is one, otherwise the .app inside the archive a
# skip_signing build produced -- so `verify` works after either build mode.
def default_ios_artifact(out, scheme)
  ipa = File.join(out, "#{scheme}.ipa")
  return ipa if File.exist?(ipa)

  app = Dir.glob(File.join(out, "#{scheme}.xcarchive", 'Products', 'Applications', '*.app')).sort.first
  app || ipa
end

# The dSYMs gym leaves inside the archive, when there is an archive. nil rather
# than a guess when there is not: `verify-ios.sh --dsym` on a path that is not
# there is a FAIL, and a missing dSYM is not what that check is about.
def default_ios_dsyms(out, scheme)
  dir = File.join(out, "#{scheme}.xcarchive", 'dSYMs')
  Dir.exist?(dir) ? dir : nil
end

# The generated Info.plist, which is where `expo prebuild` writes the version
# and the build number.
#
# `get_version_number` / `get_build_number` read the *pbxproj*, and prebuild
# leaves Xcode's own MARKETING_VERSION / CURRENT_PROJECT_VERSION defaults
# (1.0 / 1) untouched there. Proved on a real prebuild of this template with
# APP_VERSION=1.2.3 APP_BUILD_NUMBER=42: pbxproj said 1.0 / 1, Info.plist said
# 1.2.3 / 42. Asserting against the pbxproj therefore failed every single
# build, correct ones included.
#
# The scheme's own directory comes first: a prebuild leaves other Info.plist
# files under ios/ (an extension target, or a Pods one once `pod install` has
# run), and the alphabetically first glob match is not reliably the app's.
def ios_info_plist
  scheme = ENV['IOS_SCHEME'].to_s.strip
  scheme_plist = root_path('ios', scheme, 'Info.plist') unless scheme.empty?
  return scheme_plist if scheme_plist && File.exist?(scheme_plist)

  plist = Dir.glob(root_path('ios', '*', 'Info.plist')).sort.first
  UI.user_error!("No ios/*/Info.plist -- #{ios_missing_hint}") if plist.nil?

  plist
end

# Gets the release's version and build number into the iOS project and proves
# they are there, which is done differently per stack (see `native_stack`):
#
# expo  prebuild already wrote them, so this only reads them back from the
#       generated Info.plist and compares.
# bare  nothing generated them. The committed project holds whatever was last
#       checked in, so the release's numbers are stamped into the project (in
#       this checkout only, never committed) and read back from it. The target
#       is the scheme, the convention in a React Native project.
def stamp_and_assert_ios_version!
  if native_stack == 'bare'
    project = ios_xcodeproj
    increment_version_number(version_number: ENV.fetch('APP_VERSION'), xcodeproj: project)
    increment_build_number(build_number: ENV.fetch('APP_BUILD_NUMBER'), xcodeproj: project)
    assert_project_version!(
      get_version_number(xcodeproj: project, target: ENV.fetch('IOS_SCHEME')),
      get_build_number(xcodeproj: project)
    )
  else
    plist = ios_info_plist
    assert_project_version!(
      get_info_plist_value(path: plist, key: 'CFBundleShortVersionString'),
      get_info_plist_value(path: plist, key: 'CFBundleVersion')
    )
  end
end

platform :ios do
  desc 'Archive the generated iOS project (skip_signing:true for an unsigned local proof)'
  lane :build do |options|
    skip_signing = truthy?(options[:skip_signing])
    scheme = ENV.fetch('IOS_SCHEME')
    out = prepare_output_dir!(output_dir('ios'))
    ios_xcodeproj # says what is missing rather than failing inside gym

    # Before the archive, not after: an artifact labelled with the previous
    # run's numbers is indistinguishable from a correct one once it is built.
    stamp_and_assert_ios_version!

    args = {
      workspace: ios_xcworkspace,
      scheme: scheme,
      configuration: 'Release',
      clean: true,
      output_directory: out,
      output_name: "#{scheme}.ipa",
      archive_path: File.join(out, "#{scheme}.xcarchive"),
      buildlog_path: File.join(out, 'logs'),
      include_symbols: true
    }

    if skip_signing
      # A local proof: archive only, no signing identity, no .ipa. `export_method`
      # is deliberately absent -- gym would otherwise try to export.
      args[:skip_codesigning] = true
      args[:skip_package_ipa] = true
    else
      require_env!(%w[MATCH_GIT_URL MATCH_PASSWORD ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8_BASE64])
      # An ephemeral keychain, so a shared runner never keeps the certificate.
      setup_ci if ENV['CI'].to_s != ''
      match(type: 'appstore', readonly: true, app_identifier: [ENV.fetch('IOS_BUNDLE_ID')], api_key: api_key)
      args[:export_method] = 'app-store'
      # The generated project already carries the right numbers (asserted
      # above); letting Xcode manage them would overwrite them at export time.
      args[:export_options] = { manageAppVersionAndBuildNumber: false }
    end

    gym(**args)
  end

  desc 'Run the iOS artifact verification gate'
  lane :verify do |options|
    script = verify_script!('verify-ios.sh')
    out = output_dir('ios')
    scheme = ENV.fetch('IOS_SCHEME')
    path = options[:path] || default_ios_artifact(out, scheme)
    UI.user_error!("Nothing to verify at #{path} — run `fastlane ios build` first") unless File.exist?(path)

    args = ['bash', script, path]
    args << '--no-signing' if truthy?(options[:skip_signing])
    # The archive carries its own dSYMs next to the binary being verified, so
    # the UUID check is free here; without this it is a permanent skip in CI.
    dsym = options[:dsym_path] || default_ios_dsyms(out, scheme)
    args.push('--dsym', dsym) if dsym
    run_verifier(*args)
  end

  desc 'Upload the build to TestFlight for internal testers (idempotent)'
  lane :upload_internal do |options|
    require_env!(%w[ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8_BASE64 STORE_NOTES_FILE])
    build_info # asserts the artifact belongs to this version/build number
    key = api_key
    bundle_id = ENV.fetch('IOS_BUNDLE_ID')
    version = ENV.fetch('APP_VERSION')
    build_number = ENV.fetch('APP_BUILD_NUMBER')

    # Re-running a release job must not fail on "build already exists": the
    # upload is the step most likely to be retried after an unrelated flake.
    # This compares against the *highest* build number for the version, which is
    # only equivalent to "this build number is present" because the template's
    # build numbers are monotonic (`git rev-list --count`, Task 2). A scheme that
    # can reissue a lower number needs a per-build Spaceship lookup instead.
    latest = store_action(
      :latest_testflight_build_number,
      api_key: key,
      app_identifier: bundle_id,
      version: version,
      initial_build_number: 0
    )
    if latest.to_i >= build_number.to_i
      UI.important("TestFlight already has build #{version} (#{latest}) — skipping upload")
      next
    end

    args = {
      api_key: key,
      app_identifier: bundle_id,
      # artifact_dir, not output_dir: this job downloaded the build job's
      # artifacts into $WORKFLOWS_ASSETS_DIR and has nothing of its own to upload.
      ipa: options[:ipa] || File.join(artifact_dir('ios'), "#{ENV.fetch('IOS_SCHEME')}.ipa"),
      changelog: store_notes(TESTFLIGHT_NOTES_LIMIT),
      skip_submission: true,
      distribute_external: false,
      uses_non_exempt_encryption: false
    }
    internal_group = ENV['TESTFLIGHT_INTERNAL_GROUP'].to_s.strip
    args[:groups] = [internal_group] unless internal_group.empty?

    store_action(:upload_to_testflight, **args)
  end

  desc 'Promote the existing TestFlight build to the external beta group'
  lane :promote_beta do
    require_env!(%w[ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8_BASE64 TESTFLIGHT_EXTERNAL_GROUP STORE_NOTES_FILE])

    # `distribute_only: true` promotes the build that is already there; nothing
    # is re-uploaded, so beta always ships the exact binary internal testers saw.
    args = {
      api_key: api_key,
      app_identifier: ENV.fetch('IOS_BUNDLE_ID'),
      app_version: ENV.fetch('APP_VERSION'),
      build_number: ENV.fetch('APP_BUILD_NUMBER'),
      distribute_only: true,
      distribute_external: true,
      notify_external_testers: true,
      groups: [ENV.fetch('TESTFLIGHT_EXTERNAL_GROUP')],
      changelog: store_notes(TESTFLIGHT_NOTES_LIMIT)
    }
    # Omitted when no APP_REVIEW_* is set: pilot PATCHes every key it is given,
    # so passing blanks would erase the beta review contact in App Store Connect.
    review = beta_review_information
    args[:beta_app_review_info] = review unless review.empty?

    store_action(:upload_to_testflight, **args)
  end

  desc 'Submit the existing build to the App Store with metadata and release notes'
  lane :release_production do
    require_env!(%w[ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8_BASE64])
    assert_ios_metadata_dirs!(ios_metadata_path)
    assert_metadata_ready!(ios_metadata_path)
    written = write_release_notes!(ios_metadata_path, kind: :appstore, limit: APP_STORE_NOTES_LIMIT)
    UI.message("Release notes written: #{written.join(', ')}")

    args = {
      api_key: api_key,
      app_identifier: ENV.fetch('IOS_BUNDLE_ID'),
      app_version: ENV.fetch('APP_VERSION'),
      build_number: ENV.fetch('APP_BUILD_NUMBER'),
      # The binary is already in App Store Connect (upload_internal put it
      # there); this lane only submits metadata and the review request.
      skip_binary_upload: true,
      skip_screenshots: true,
      metadata_path: ios_metadata_path,
      submit_for_review: true,
      automatic_release: true,
      phased_release: truthy?(ENV['IOS_PHASED_RELEASE']),
      # precheck needs its own App Store Connect session and fails the whole
      # submission on a warning; the metadata gate above is the check we own.
      run_precheck_before_submit: false,
      force: true,
      submission_information: { add_id_info_uses_idfa: false, export_compliance_uses_encryption: false }
    }
    # Omitted when no APP_REVIEW_* is set: deliver derives demoAccountRequired
    # from this hash whether or not a demo user is in it, so an unconfigured run
    # would clear the flag on an app that does require a demo account.
    review = review_information
    args[:app_review_information] = review unless review.empty?

    store_action(:upload_to_app_store, **args)
  end

  desc 'Push the baseline store listing from fastlane/metadata/ios to App Store Connect (no binary, no review submission, no release notes)'
  lane :sync_metadata do |options|
    assert_metadata_sync_enabled!
    require_env!(%w[ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8_BASE64])
    source = ios_metadata_path
    assert_metadata_locales!(source)
    assert_ios_metadata_dirs!(source)
    assert_metadata_ready!(source)

    # Apple's constraint, not ours: name, subtitle, keywords, categories and
    # screenshots only exist on a version that is being prepared. `live:true`
    # (or IOS_METADATA_EDIT_LIVE) edits the live version instead, which Apple
    # allows for description, promotional text, the URLs and the copyright and
    # nothing else (deliver/lib/deliver/upload_metadata.rb:67).
    live = truthy?(options[:live] || ENV['IOS_METADATA_EDIT_LIVE'])
    # deliver writes demo_account_required from whether a demo user is in this
    # hash - unconditionally, whether or not the hash is present at all
    # (deliver/lib/deliver/upload_metadata.rb:690). An unconfigured run must
    # not send an empty hash and flip that flag off on an app that does
    # require a demo account, so the staged tree keeps review_information only
    # when the APP_REVIEW_* environment has something to put in it - and never
    # in live mode, where review detail is not editable.
    review = live ? {} : review_information
    excluded_dirs = SYNC_EXCLUDED_DIRS + (review.empty? ? %w[review_information] : [])
    screenshots = !live && ios_screenshots?

    with_baseline_metadata(source, exclude_dirs: excluded_dirs) do |staged|
      args = {
        api_key: api_key,
        app_identifier: ENV.fetch('IOS_BUNDLE_ID'),
        metadata_path: staged,
        # No app_version, and skip_app_version_update on top of it: deliver
        # creates or renames a version only when it is given one
        # (deliver/lib/deliver/runner.rb:58). This lane must never move the
        # version App Store Connect is holding, and must never be the thing
        # that opens one.
        skip_app_version_update: true,
        skip_binary_upload: true,
        skip_metadata: false,
        # The three that make this a listing edit rather than a release:
        submit_for_review: false,
        run_precheck_before_submit: false,
        edit_live: live,
        # Neither automatic_release nor auto_release_date: both write the
        # version's releaseType, which belongs to release_production.
        force: true, # no HTML preview to confirm on a runner
        skip_screenshots: !screenshots,
        # When screenshots are staged, this must be true: deliver deletes
        # every display type for a staged locale before uploading what is
        # staged, so an en-US holding iPhone shots only would otherwise erase
        # that locale's existing iPad set (deliver/lib/deliver/upload_screenshots.rb:82-89).
        overwrite_screenshots: screenshots
      }
      if screenshots
        # A sibling of the staged metadata, never inside it: `screenshots` is
        # the one directory name deliver rejects under metadata_path.
        staged_shots = File.join(File.dirname(staged), 'screenshots')
        FileUtils.cp_r(ios_screenshots_path, staged_shots)
        args[:screenshots_path] = staged_shots
      end
      rating = ios_app_rating_config_path(staged)
      args[:app_rating_config_path] = rating if rating
      args[:app_review_information] = review unless review.empty?

      unless live
        # The default path needs a version in "Prepare for Submission" and
        # waits a long time to find out it has none:
        # verify_available_version_languages! -> fetch_edit_app_store_version
        # retries 7 times with a 20,40,80,160,300,300,300 s backoff
        # (deliver/lib/deliver/upload_metadata.rb:464-481) and then raises
        # "Cannot update languages - could not find an editable version"
        # (:557-560), having written nothing. Live mode is the one that does
        # not wait: it fetches the live version first, with no retry (:107).
        UI.important('With no version in preparation deliver retries for about 20 minutes and then ' \
                     'fails without writing anything. Use live:true (or IOS_METADATA_EDIT_LIVE=true) ' \
                     'to edit the live version\'s smaller editable subset instead.')
      end

      # deliver deletes the version's App Store review attachment on every
      # push: review_attachment_file(version) runs unconditionally and, with
      # no app_review_attachment_file given, removes whatever is attached
      # (deliver/lib/deliver/upload_metadata.rb:752-768). Re-upload it in the
      # console after a sync if the app uses one.
      store_action(:upload_to_app_store, **args)
    end
  end

  desc 'Pull the App Store listing and screenshots into the repo (overwrites local files - review the diff)'
  lane :pull_metadata do
    require_env!(%w[ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8_BASE64])
    warn_metadata_overwrite!('fastlane/metadata/ios and fastlane/screenshots')
    bundle_id = ENV.fetch('IOS_BUNDLE_ID')

    if ENV['DRY_RUN'] == '1'
      UI.important("[dry-run] deliver download_metadata + download_screenshots for #{bundle_id} " \
                   "into #{ios_metadata_path} and #{ios_screenshots_path}")
      next
    end

    # Commands, not actions - so they are a subprocess with its own key file.
    # No --use_live_version: deliver's download_metadata and
    # download_screenshots ignore it. Both take the *latest* App Store version
    # and consult only `app_version`
    # (deliver/lib/deliver/commands_generator.rb:172-200), so passing it would
    # only suggest a choice the download does not make. `IOS_METADATA_EDIT_LIVE`
    # belongs to sync_metadata alone.
    with_asc_api_key_file do |key_path|
      common = ['--api_key_path', key_path, '--app_identifier', bundle_id]
      sh('bundle', 'exec', 'fastlane', 'deliver', 'download_metadata',
         *common, '--metadata_path', ios_metadata_path, '--force')
      sh('bundle', 'exec', 'fastlane', 'deliver', 'download_screenshots',
         *common, '--screenshots_path', ios_screenshots_path)
    end

    # shared.rb cannot call `sh` itself (see its header) - it only builds the
    # argv, and it is run here. Absolute paths: the lane's cwd is `fastlane/`,
    # not the repo root (see metadata_diff_commands).
    metadata_diff_commands(ios_metadata_path, ios_screenshots_path).each { |argv| sh(*argv) }
  end

  desc 'Control the 7-day phased release of the live version (action:pause|resume|complete)'
  lane :phased do |options|
    require_env!(%w[ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8_BASE64])
    action = options[:action].to_s
    UI.user_error!("phased needs action:pause|resume|complete (got #{action.inspect})") unless %w[pause resume complete].include?(action)

    if ENV['DRY_RUN'] == '1'
      # Spaceship talks to App Store Connect the moment it is authenticated, so
      # the rehearsal has to stop before that rather than inside it.
      UI.important("[dry-run] phased #{action} for #{ENV.fetch('IOS_BUNDLE_ID')}")
      next
    end

    # There is no fastlane action for this; Spaceship is the API. Asking the
    # api_key helper to set the Spaceship token is what authenticates it.
    app_store_connect_api_key(
      key_id: ENV.fetch('ASC_KEY_ID'),
      issuer_id: ENV.fetch('ASC_ISSUER_ID'),
      key_content: ENV.fetch('ASC_KEY_P8_BASE64'),
      is_key_content_base64: true,
      in_house: false,
      set_spaceship_token: true
    )

    app = Spaceship::ConnectAPI::App.find(ENV.fetch('IOS_BUNDLE_ID'))
    UI.user_error!("No app found for #{ENV.fetch('IOS_BUNDLE_ID')}") if app.nil?
    version = app.get_live_app_store_version
    UI.user_error!('No live App Store version to phase') if version.nil?
    phased_release = version.fetch_app_store_version_phased_release
    UI.user_error!('The live version has no phased release configured') if phased_release.nil?

    phased_release.public_send(action)
    UI.success("Phased release #{action}d for #{ENV.fetch('APP_VERSION')}")
  end

  desc 'Download and upload dSYMs for the crash reporter (opt-in)'
  lane :upload_symbols do |options|
    require_env!(%w[ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8_BASE64])
    dsym_path = options[:dsym_path]

    if dsym_path.nil?
      out = prepare_output_dir!(output_dir('ios'))
      store_action(
        :download_dsyms,
        api_key: api_key,
        app_identifier: ENV.fetch('IOS_BUNDLE_ID'),
        version: ENV.fetch('APP_VERSION'),
        build_number: ENV.fetch('APP_BUILD_NUMBER'),
        output_directory: out
      )
      dsym_path = out
    end

    # Symbol upload is crash-reporter specific and this template ships without
    # one; the dSYMs are on disk and the runbook says where to point them.
    UI.important("dSYMs are at #{dsym_path}. Wire your crash reporter's upload here (see the release runbook).")
    dsym_path
  end
end
