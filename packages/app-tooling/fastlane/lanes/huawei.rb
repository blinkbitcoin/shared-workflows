# Huawei AppGallery Connect: upload the signed Android App Bundle and submit it
# as an internal test version, an open test version or a formal release.
#
# AppGallery has one version slot per app and no tracks, so a tier is a flavour
# of the submit rather than a destination: each tier replaces what the last one
# put there, and there is no promote endpoint to move a build between them.
# Binary only: AppGallery's listing fields stay console-only, so
# there is no sync_metadata counterpart here. The lane lives under
# `platform :android` because shared-workflows' fastlane.sh runs
# `fastlane <platform> <lane>` and accepts only ios or android, which makes a
# top-level lane unreachable from a release run.
HUAWEI_ENV = %w[HUAWEI_CLIENT_ID HUAWEI_CLIENT_SECRET HUAWEI_APP_ID].freeze
HUAWEI_NOTES_LIMIT = 300 # AppGallery accepts a changelog of 10 to 300 characters
HUAWEI_NOTES_MINIMUM = 10
# The plugin's own default is 10 seconds, which lands while AppGallery is still
# compiling the bundle.
HUAWEI_SUBMIT_DELAY_SECONDS = 60
# The length of a test version's window, in days. AppGallery's own default is
# 80 and the console refuses more than 90, so 89 is the most the lane will pass.
HUAWEI_TEST_DAYS = 80
HUAWEI_TEST_DAYS_MAX = 89
# The format the plugin parses both ends of the window back out of. It keeps the
# offset through Time.parse, so a value computed in UTC round-trips byte-exact.
HUAWEI_TEST_TIME_FORMAT = '%Y-%m-%dT%H:%M:%S+0000'
# The releaseState values of the app record that mean AppGallery is already busy
# with this app's one version slot and would refuse the next submission.
HUAWEI_BUSY_RELEASE_STATES = {
  3 => 'releasing',
  4 => 'under review',
  5 => 'pending update review',
  12 => 'under pre-review'
}.freeze

def huawei_credentials
  {
    client_id: ENV.fetch('HUAWEI_CLIENT_ID'),
    client_secret: ENV.fetch('HUAWEI_CLIENT_SECRET'),
    app_id: ENV.fetch('HUAWEI_APP_ID')
  }
end

def huawei_submit_delay_seconds
  configured = ENV['HUAWEI_SUBMIT_DELAY_SECONDS'].to_s.strip
  return HUAWEI_SUBMIT_DELAY_SECONDS if configured.empty?
  unless /\A\d+\z/.match?(configured)
    UI.user_error!("HUAWEI_SUBMIT_DELAY_SECONDS must be a whole number of seconds, got #{configured.inspect}")
  end

  configured.to_i
end

# The plugin's token helper returns nil on an authentication failure and the
# upload action then only prints a message, so a wrong or revoked secret would
# be a green job that uploaded nothing. Asking for the app record first makes
# that red before any binary moves. get_app_info answers nil when the token is
# nil, an empty hash when the app record is not visible to this client, and
# false when AppGallery refused the request (the plugin's own user_error!
# normally raises before that return, so false is a belt-and-braces case).
def assert_huawei_credentials!(credentials)
  info = store_action(:huawei_appgallery_connect_get_app_info, **credentials)
  blank = !info || (info.respond_to?(:empty?) && info.empty?)
  return info unless blank # returned so the caller reads the release state out of it

  UI.user_error!(
    "AppGallery Connect returned no app record for HUAWEI_APP_ID #{ENV.fetch('HUAWEI_APP_ID')}: " \
    'the client id and client secret pair is wrong or revoked, or the app id ' \
    'belongs to another team (see the release runbook)'
  )
end

# The configured length of the test window, in days, clamped to what AppGallery
# accepts.
def huawei_test_days
  configured = ENV['HUAWEI_TEST_DAYS'].to_s.strip
  return HUAWEI_TEST_DAYS if configured.empty?
  unless /\A\d+\z/.match?(configured) && configured.to_i.positive?
    UI.user_error!("HUAWEI_TEST_DAYS must be a whole number of days above zero, got #{configured.inspect}")
  end

  days = configured.to_i
  return days unless days > HUAWEI_TEST_DAYS_MAX

  UI.important(
    "HUAWEI_TEST_DAYS is #{days}, above the #{HUAWEI_TEST_DAYS_MAX}-day ceiling " \
    "AppGallery accepts - submitting an #{HUAWEI_TEST_DAYS_MAX}-day test window instead"
  )
  HUAWEI_TEST_DAYS_MAX
end

# Both ends of the test window, computed in UTC. The plugin's own default
# formats a *local* time with a hardcoded +0000 suffix, so the window it picks
# is hours out anywhere but a UTC machine; the lane never lets it default.
def huawei_test_window(days)
  start = Time.now.utc + 3600 # the window has to open ahead of the submission
  {
    test_start_time: start.strftime(HUAWEI_TEST_TIME_FORMAT),
    test_end_time: (start + (days * 24 * 60 * 60)).strftime(HUAWEI_TEST_TIME_FORMAT)
  }
end

# The name of the state AppGallery is busy with, or nil when the app record says
# nothing the lane recognises. Deliberately fail-open: whether a *testing*
# submission moves the record into one of these states is unverified, so an
# unknown or absent answer has to read as "go ahead" rather than "stop".
def huawei_version_busy(info)
  # A Hash only: the plugin's get_app_info returns the appInfo hash, nil or
  # false, and anything else must fall through rather than raise on `[]`.
  return nil unless info.is_a?(Hash)

  state = (info[:releaseState] || info['releaseState']).to_s.strip
  return nil unless /\A\d+\z/.match?(state)

  HUAWEI_BUSY_RELEASE_STATES[state.to_i]
end

# The submit body that makes the upload a test version. `skip_manual_review`
# true is the internal tier (automated review, hours, up to 100 testers), false
# is open testing (manual review, 1 to 3 working days, up to 5,000 testers).
#
# `feedback_email` is passed only when it is configured: the plugin puts the key
# in the request body whatever its value, and AppGallery shows the address to
# testers, so a blank one is worse than none at all.
def huawei_testing_submit(skip_manual_review:)
  submit = { use_testing_version: true, skip_manual_review: skip_manual_review }
  email = ENV['HUAWEI_FEEDBACK_EMAIL'].to_s.strip
  submit[:feedback_email] = email unless email.empty?
  submit
end

# The upload all three tiers share. `submit` is what makes the tier: a testing
# body for the internal and beta tiers, nothing at all for the release.
def huawei_upload!(aab: nil, submit: {})
  assert_huawei_uploads_enabled! # per-store gate on top of STORE_UPLOADS_ENABLED
  require_env!(HUAWEI_ENV)
  build_info # asserts the artifact belongs to this version/build number
  bundle = aab || File.join(artifact_dir('android'), 'app-release.aab')
  unless File.exist?(bundle) || ENV['DRY_RUN'] == '1'
    UI.user_error!("No Android App Bundle at #{bundle} - the huawei-binary job stages it from the release tag")
  end

  # Configuration is checked before the pre-flight, so a typo in the delay or
  # the window costs no real AppGallery call.
  submit_delay = huawei_submit_delay_seconds
  submit = submit.merge(huawei_test_window(huawei_test_days)) if submit[:use_testing_version]

  credentials = huawei_credentials
  # No idempotency query: get_app_info answers app-level fields only, with no
  # package version in them. A re-run re-uploads, and AppGallery rejects a
  # duplicate version code. What the record does carry is the release state, and
  # a submission already in flight blocks the next one on the same app - so the
  # job withholds the upload with a message rather than going red on a review
  # queue that is not ours.
  busy = huawei_version_busy(assert_huawei_credentials!(credentials))
  if busy
    UI.important(
      "AppGallery already has a version #{busy} for app #{ENV.fetch('HUAWEI_APP_ID')} - " \
      'skipping the upload. A version under review blocks the next submission; ' \
      're-run this job once the console shows it cleared'
    )
    return
  end

  args = credentials.merge(
    apk_path: bundle,
    is_aab: true,
    submit_for_review: true,
    delay_before_submit_for_review: submit_delay
  ).merge(submit)
  with_huawei_changelog do |path|
    args[:changelog_path] = path if path
    store_action(:huawei_appgallery_connect, **args)
  end
end

# AppGallery takes the changelog as a file path, and the file it takes is a
# throwaway: nothing in fastlane/metadata describes an AppGallery release.
def with_huawei_changelog
  require_env!(%w[STORE_NOTES_FILE])
  text = store_notes(HUAWEI_NOTES_LIMIT)
  if text.length < HUAWEI_NOTES_MINIMUM
    UI.important(
      "Release notes are #{text.length} characters, below AppGallery's " \
      "#{HUAWEI_NOTES_MINIMUM}-character floor - uploading without a changelog"
    )
    return yield(nil)
  end
  if ENV['DRY_RUN'] == '1'
    UI.important("[dry-run] would write an AppGallery changelog (#{text.length} characters)")
    return yield('[dry-run]/changelog.txt')
  end

  require 'tmpdir'
  Dir.mktmpdir('huawei-changelog') do |dir|
    path = File.join(dir, 'changelog.txt')
    File.write(path, "#{text}\n")
    yield(path)
  end
end

platform :android do
  desc 'Upload the Android App Bundle to Huawei AppGallery Connect as an internal test version'
  lane :upload_huawei_internal do |options|
    huawei_upload!(aab: options[:aab], submit: huawei_testing_submit(skip_manual_review: true))
  end

  desc 'Submit the released Android App Bundle to Huawei AppGallery Connect open testing'
  lane :promote_huawei_beta do |options|
    # Re-uploaded from the tag rather than promoted: AppGallery has no promote
    # endpoint, the internal submission may have been skipped over a busy slot
    # or superseded by later pushes, and build_info on the staged bundle is
    # what gives this tier the same bytes-from-the-tag guarantee the Play and
    # TestFlight promotions have.
    huawei_upload!(aab: options[:aab], submit: huawei_testing_submit(skip_manual_review: false))
  end

  desc 'Upload the Android App Bundle to Huawei AppGallery Connect and submit it for release'
  lane :upload_huawei do |options|
    huawei_upload!(aab: options[:aab]) # no testing body: the formal release
  end
end
