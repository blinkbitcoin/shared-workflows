# Helpers shared by every lane. Two constraints keep this file honest:
#
#   1. It is loaded standalone by fastlane/test/lanes_test.rb, without fastlane
#      running. So it may only reference `UI` (stubbed in the tests) and plain
#      Ruby -- no `lane`, no `sh`, no fastlane action outside `store_action`.
#   2. Every call that talks to a store goes through `store_action`, which is
#      what makes DRY_RUN=1 a real, testable rehearsal of a release.
require 'json'

# Argument names whose values are credentials. A DRY_RUN=1 rehearsal is exactly
# the run someone pastes into a PR or leaves in a public Actions log, and
# GitHub only masks values registered as secrets in that job -- so the dry-run
# log redacts these itself. The pattern catches names this list has not met yet.
REDACTED_ARG_KEYS = %i[
  api_key api_token app_specific_password auth_token client_id demo_password
  json_key json_key_data key_content key_password keystore_password
  match_password password private_key store_password token
].freeze
# Case-insensitive: fastlane and the workflows both pass keys through from
# environment names, so a `JSON_KEY` or `Password` must redact like `json_key`.
REDACTED_ARG_PATTERN = /password|secret|token|private_key|key_content|json_key/i

# Fails with a pointer to the runbook rather than a stack trace when a release
# is started without its credentials.
def require_env!(keys)
  missing = keys.reject { |k| ENV[k].to_s.strip != '' }
  UI.user_error!("Missing env: #{missing.join(', ')} (see the release runbook)") unless missing.empty?
end

# What each store action returns under DRY_RUN=1. A dry run only rehearses the
# whole lane if the canned value has the shape the lane goes on to use: an
# idempotency check that destructures an array, or compares a build number,
# would otherwise blow up on the generic `[]` and hide everything after it.
#
# `[]` stays the default (an empty result reads as "nothing there yet", which is
# what makes a dry run walk the upload path rather than the skip path), so only
# actions whose result is actually consumed need an entry here.
DRY_RUN_RESULTS = {
  google_play_track_version_codes: [],
  latest_testflight_build_number: 0,
  upload_to_testflight: nil,
  upload_to_app_store: nil,
  download_dsyms: nil,
  # A non-empty stand-in: the Huawei lane treats a blank answer as an
  # authentication failure, which a rehearsal must not trip over.
  huawei_appgallery_connect_get_app_info: { 'appName' => '[dry-run]' },
  huawei_appgallery_connect: nil
}.freeze
DRY_RUN_DEFAULT_RESULT = [].freeze

# The single gate between a lane and the outside world. With DRY_RUN=1 nothing
# is uploaded or promoted: the call is logged and canned data is returned, so a
# lane can be walked end to end on a laptop or in a CI dry run.
def store_action(name, **args)
  if ENV['DRY_RUN'] == '1'
    UI.important("[dry-run] #{name} #{JSON.generate(loggable_args(args))}")
    return DRY_RUN_RESULTS.fetch(name.to_sym, DRY_RUN_DEFAULT_RESULT)
  end

  args.empty? ? send(name) : send(name, **args)
end

# Credential-shaped values replaced with `[redacted]`, nested hashes included
# (`api_key:` is itself a hash whose `key_content` is the App Store Connect .p8).
def redacted_arg?(key)
  REDACTED_ARG_KEYS.include?(key.to_sym) || REDACTED_ARG_PATTERN.match?(key.to_s)
end

# Arrays are descended too: `groups: [{ name:, password: }]` and similar
# list-shaped arguments would otherwise print a secret the sibling hash form
# redacts.
def loggable_value(value)
  case value
  when Hash then loggable_args(value)
  when Array then value.map { |item| loggable_value(item) }
  else value
  end
end

def loggable_args(args)
  args.to_h do |key, value|
    next [key, '[redacted]'] if redacted_arg?(key)

    [key, loggable_value(value)]
  end
end

# App Store Connect API key, assembled from the three secrets CI holds. The .p8
# is passed base64-encoded so it survives being a single-line secret.
#
# Under DRY_RUN=1 it is a placeholder: building the real key signs a JWT with
# the .p8, so a rehearsal would otherwise demand live Apple credentials to
# reach the first thing it is supposed to be able to rehearse without them.
def api_key
  if ENV['DRY_RUN'] == '1'
    UI.important('[dry-run] app_store_connect_api_key (no App Store Connect session)')
    return { key_id: ENV['ASC_KEY_ID'].to_s, issuer_id: ENV['ASC_ISSUER_ID'].to_s, dry_run: true }
  end

  app_store_connect_api_key(
    key_id: ENV.fetch('ASC_KEY_ID'),
    issuer_id: ENV.fetch('ASC_ISSUER_ID'),
    key_content: ENV.fetch('ASC_KEY_P8_BASE64'),
    is_key_content_base64: true,
    in_house: false
  )
end

STORE_NOTES_SUFFIX = ' [+more on GitHub]'.freeze

# Store-ready release notes, truncated at a word boundary with a pointer to the
# full changelog. `limit` is the store's own cap (App Store 4000, Play 500) and
# is counted in characters, which is how both stores count. The result is never
# nil and never longer than `limit`, whatever `limit` is.
def store_notes(limit)
  truncate_store_text(File.read(ENV.fetch('STORE_NOTES_FILE')).strip, limit)
end

# The one truncation rule. Both callers -- the single-locale file and the
# per-locale store-notes.json -- go through it, so a note that reaches a store
# is cut the same way whichever source it came from.
def truncate_store_text(text, limit)
  return '' if limit <= 0
  return text if text.length <= limit
  # No room for the pointer: hard-cut instead of returning only a suffix.
  return text[0, limit].rstrip if limit <= STORE_NOTES_SUFFIX.length

  window = text[0, limit - STORE_NOTES_SUFFIX.length]
  boundary = window.rindex(/\s/)
  # Only honour a word boundary that keeps most of the window; otherwise a note
  # whose only space is near the start would lose nearly all of its content.
  cut = boundary && boundary > window.length / 2 ? window[0, boundary] : window
  "#{cut.rstrip}#{STORE_NOTES_SUFFIX}"
end

# build-info.json is written by the build job. Reading it here is the seam that
# catches a lane being pointed at an artifact from a different release.
def build_info
  info = JSON.parse(File.read(ENV.fetch('BUILD_INFO_FILE', 'build-info.json')))
  UI.user_error!("build-info version #{info['version']} != APP_VERSION #{ENV['APP_VERSION']}") unless info['version'] == ENV['APP_VERSION']
  UI.user_error!("build-info buildNumber #{info['buildNumber']} != APP_BUILD_NUMBER #{ENV['APP_BUILD_NUMBER']}") unless info['buildNumber'].to_s == ENV['APP_BUILD_NUMBER']

  info
end

# App Review contact details live in the environment, not in the repo: the
# metadata files under fastlane/metadata/ hold blanks and lanes fill them here.
#
# Blank values are dropped, and an empty hash means "nothing configured": both
# stores treat a field they are *given* as an instruction to overwrite, so
# sending blanks would clear the contact, demo account and review notes someone
# entered in the web UI -- worse than not touching them. Callers omit the
# argument entirely when this comes back empty. deliver also derives
# `demoAccountRequired` from the hash unconditionally
# (deliver/lib/deliver/upload_metadata.rb), which is the other reason it is
# all-or-nothing rather than per-key.
def review_information
  {
    first_name: ENV['APP_REVIEW_FIRST_NAME'],
    last_name: ENV['APP_REVIEW_LAST_NAME'],
    phone_number: ENV['APP_REVIEW_PHONE'],
    email_address: ENV['APP_REVIEW_EMAIL'],
    demo_user: ENV['APP_REVIEW_DEMO_USER'],
    demo_password: ENV['APP_REVIEW_DEMO_PASSWORD'],
    notes: ENV['APP_REVIEW_NOTES']
  }.reject { |_, value| value.to_s.strip.empty? }
end

# The same contact details in pilot's key names. deliver and pilot spell every
# field differently and pilot rejects an unknown key outright, so the two
# shapes are built separately rather than renamed at the call site.
# Valid keys per pilot/lib/pilot/options.rb: contact_email, contact_first_name,
# contact_last_name, contact_phone, demo_account_required, demo_account_name,
# demo_account_password, notes.
#
# pilot is the stricter of the two: build_manager.rb keys off `info.key?`, not
# on the value being present, so a blank here really does erase what is in App
# Store Connect.
def beta_review_information
  demo_user = ENV['APP_REVIEW_DEMO_USER'].to_s.strip
  info = {
    contact_first_name: ENV['APP_REVIEW_FIRST_NAME'],
    contact_last_name: ENV['APP_REVIEW_LAST_NAME'],
    contact_phone: ENV['APP_REVIEW_PHONE'],
    contact_email: ENV['APP_REVIEW_EMAIL'],
    demo_account_name: ENV['APP_REVIEW_DEMO_USER'],
    demo_account_password: ENV['APP_REVIEW_DEMO_PASSWORD'],
    notes: ENV['APP_REVIEW_NOTES']
  }.reject { |_, value| value.to_s.strip.empty? }
  info[:demo_account_required] = true unless demo_user.empty?
  info
end

# ---------------------------------------------------------------------------
# Options, paths and env coercion
# ---------------------------------------------------------------------------

# fastlane passes `lane build skip_signing:true` through as the *string*
# "true", while a lane invoked from another lane passes a real boolean. Both
# have to mean the same thing or a CLI-only flag silently does nothing.
def truthy?(value)
  %w[true 1 yes].include?(value.to_s.strip.downcase)
end

# fastlane runs every lane with the working directory set to `fastlane/`, while
# the unit tests, the Makefile and every workflow speak in paths from the
# directory that *contains* it. Anchoring on that directory is what stops a lane
# from quietly finding nothing -- `metadata_locales` returning an empty list from
# the wrong directory writes no release notes and raises nothing.
#
# The directory is the one fastlane itself found: FastlaneFolder.path is
# `./fastlane/` from the project root and `.` from inside it, which is where a
# lane runs. These lanes ship in the app-tooling package, under node_modules, so
# they cannot recognise the app's directory by a lanes/ folder in it; fastlane
# knows which Fastfile it loaded. Without fastlane (the unit tests load this file
# standalone) it is the working directory.
def fastlane_folder
  return nil unless defined?(FastlaneCore::FastlaneFolder)

  folder = FastlaneCore::FastlaneFolder.path
  folder && File.expand_path(folder)
end

def repo_root
  folder = fastlane_folder
  folder ? File.expand_path('..', folder) : Dir.pwd
end

# The app's fastlane directory: where its metadata/ and screenshots/ live.
def fastlane_path(*parts)
  File.expand_path(File.join(fastlane_folder || root_path('fastlane'), *parts))
end

def root_path(*parts)
  File.expand_path(File.join(repo_root, *parts))
end

# Where build artifacts land. CI overrides it so the upload job finds the same
# paths the build job wrote, without either side hard-coding the other's layout.
def output_dir(platform)
  dir = ENV['WORKFLOWS_OUTPUT_DIR'].to_s.strip
  return root_path('artifacts', platform.to_s) if dir.empty?

  File.absolute_path?(dir) ? dir : root_path(dir)
end

# The directory a lane *reads* a finished artifact from, which is not the one
# it would write to. A build job archives into $WORKFLOWS_OUTPUT_DIR; a publish job
# never builds anything -- it downloads the build job's artifacts into
# $WORKFLOWS_ASSETS_DIR and uploads from there. Reading $WORKFLOWS_OUTPUT_DIR in a publish
# job pointed the upload lanes one directory above the binaries, which failed
# the very first store stage of every run.
#
# Precedence, highest first:
#   1. the lane's own `ipa:` / `aab:` / `apk:` option (handled at the call site)
#   2. $WORKFLOWS_ASSETS_DIR   -- the download directory in a publish job
#   3. $WORKFLOWS_OUTPUT_DIR   -- the build output directory (via output_dir)
#
# A set-but-missing $WORKFLOWS_ASSETS_DIR falls through rather than failing here: it
# means nothing was downloaded, and `output_dir` is then the honest answer for
# a lane run on a laptop with a stale variable in its shell.
def artifact_dir(platform)
  assets = ENV['WORKFLOWS_ASSETS_DIR'].to_s.strip
  return assets if !assets.empty? && Dir.exist?(assets)

  output_dir(platform)
end

# sha256 of a file, in the hex form every other tool in the release path prints.
def file_sha256(path)
  require 'digest'
  Digest::SHA256.file(path).hexdigest
end

# build-info.json is written before the artifacts exist, so its `artifacts`
# object starts empty and the "APK derived from the exact AAB" gate had nothing
# to compare against. The build lane is the only place that knows the checksums
# of the AAB Play will receive and of the universal APK extracted from that same
# bundle, so it merges them in here.
#
# The source file is copied rather than rewritten: it is an input to this build
# (the publish job reads the same one), and a lane that edited it in place would
# make a re-run of the build depend on how far the previous run got.
def write_build_info_artifacts!(dir, artifacts)
  source = ENV['BUILD_INFO_FILE'].to_s.strip
  source = root_path('build-info.json') if source.empty?
  unless File.exist?(source)
    UI.important("No build-info.json at #{source} — artifact checksums not recorded")
    return nil
  end

  info = JSON.parse(File.read(source))
  info['artifacts'] = (info['artifacts'] || {}).merge(artifacts.transform_keys(&:to_s))
  destination = File.join(dir, 'build-info.json')
  File.write(destination, "#{JSON.pretty_generate(info)}\n")
  destination
end

def prepare_output_dir!(dir)
  require 'fileutils'
  FileUtils.mkdir_p(dir)
  dir
end

# The native stack the app is built on, which the workflows resolve once
# (scripts/lib/native-stack.sh) and export to every lane: `expo`, where ios/ and
# android/ are `expo prebuild` output, or `bare`, where they are committed source.
# Unset is `expo`, which is how the lanes behaved before there was a choice.
NATIVE_STACKS = %w[expo bare].freeze

def native_stack
  stack = ENV['WORKFLOWS_NATIVE_STACK'].to_s.strip
  return 'expo' if stack.empty?

  UI.user_error!("WORKFLOWS_NATIVE_STACK is #{stack}, expected one of: #{NATIVE_STACKS.join(', ')}") unless NATIVE_STACKS.include?(stack)

  stack
end

# What to do when ios/ has nothing in it, which differs by stack: an Expo app has
# not been prebuilt, a bare app is missing what it commits.
def ios_missing_hint
  if native_stack == 'bare'
    'check that the app commits its ios/ project and that `bundle exec pod install` has run'
  else
    'run `pnpm expo prebuild` first (and `bundle exec pod install`)'
  end
end

# The project is discovered rather than assumed: a missing one is worth saying
# plainly instead of failing inside gym.
def ios_xcodeproj
  project = Dir.glob(root_path('ios', '*.xcodeproj')).sort.first
  UI.user_error!("No ios/*.xcodeproj -- #{ios_missing_hint}") if project.nil?

  project
end

def ios_xcworkspace
  workspace = Dir.glob(root_path('ios', '*.xcworkspace')).sort.first
  UI.user_error!("No ios/*.xcworkspace -- #{ios_missing_hint}") if workspace.nil?

  workspace
end

# The project carries the version and build number the release was given.
# Checking them here, before the archive, is what stops a release from producing
# an artifact labelled with the previous run's numbers.
def assert_project_version!(version, build_number)
  expected_version = ENV.fetch('APP_VERSION')
  expected_build = ENV.fetch('APP_BUILD_NUMBER')
  fix = native_stack == 'bare' ? 'the stamp did not take' : 're-run prebuild'
  UI.user_error!("Project version #{version} != APP_VERSION #{expected_version} (#{fix})") unless version.to_s == expected_version
  UI.user_error!("Project build number #{build_number} != APP_BUILD_NUMBER #{expected_build} (#{fix})") unless build_number.to_s == expected_build
end

# The release verifiers are the shared tooling's (release/ in
# @blinkbitcoin/app-tooling). These lanes ship in that package, so they are found
# beside them, whichever node_modules the package was installed into.
VERIFIERS = File.expand_path('../../release', __dir__).freeze

# WORKFLOWS_VERIFIERS_DIR runs the lanes against another copy of the verifiers,
# which is how the unit tests give each lane a directory of its own.
def verifiers_dir
  override = ENV['WORKFLOWS_VERIFIERS_DIR'].to_s.strip
  override.empty? ? VERIFIERS : override
end

def verify_script!(name)
  path = File.join(verifiers_dir, name)
  UI.user_error!("Missing #{path} (the release verifier; reinstall @blinkbitcoin/app-tooling)") unless File.exist?(path)

  path
end

# fastlane runs an action from fastlane/, and the verifiers read the repository
# they check from the directory they start in (build-info.json, .env.example,
# the store metadata). Started anywhere else they would skip those checks
# rather than fail, so they always start at the repository root.
def run_verifier(*args)
  Dir.chdir(repo_root) { sh(*args) }
end

# The metadata trees, anchored at the repo root for the same reason.
def ios_metadata_path
  fastlane_path('metadata', 'ios')
end

def android_metadata_path
  fastlane_path('metadata', 'android')
end

# Play credentials arrive either as JSON content (a single-line secret) or as a
# decoded file. supply takes both, under different argument names.
def play_json_key_args
  data = ENV['PLAY_SERVICE_ACCOUNT_JSON'].to_s.strip
  return { json_key_data: data } unless data.empty?

  path = ENV['PLAY_SERVICE_ACCOUNT_JSON_PATH'].to_s.strip
  return { json_key: path } unless path.empty?

  UI.user_error!('Missing env: PLAY_SERVICE_ACCOUNT_JSON or PLAY_SERVICE_ACCOUNT_JSON_PATH (see the release runbook)')
end

# bundletool ships as a jar on some machines and a wrapper script on others;
# neither is installed by default on a CI runner. Returning the invocation as
# argv keeps the lane free of shell quoting.
def bundletool_command
  return ['bundletool'] if executable_on_path?('bundletool')

  jar = ENV['BUNDLETOOL_JAR'].to_s.strip
  return ['java', '-jar', jar] if !jar.empty? && File.exist?(jar)

  UI.user_error!('bundletool not found: `brew install bundletool`, or download bundletool-all.jar and set BUNDLETOOL_JAR (see the release runbook)')
end

def executable_on_path?(name)
  ENV['PATH'].to_s.split(File::PATH_SEPARATOR).any? do |dir|
    next false if dir.empty?

    File.executable?(File.join(dir, name)) && !File.directory?(File.join(dir, name))
  end
end

# ---------------------------------------------------------------------------
# Release notes and metadata
# ---------------------------------------------------------------------------

# Locale directories under a metadata tree. `review_information` and the
# screenshot/changelog folders live next to the locales, so the name has to
# look like a locale rather than merely be a directory.
LOCALE_DIR_PATTERN = /\A[a-z]{2,3}(-[A-Za-z]{2,4})?\z/

def metadata_locales(metadata_path)
  return [] unless Dir.exist?(metadata_path)

  Dir.children(metadata_path)
     .select { |name| File.directory?(File.join(metadata_path, name)) && LOCALE_DIR_PATTERN.match?(name) }
     .sort
end

# store-notes.json (written by the shared gen-store-notes program) holds per-locale text
# for each surface: { "<locale>": { "testflight": ..., "play": ..., "appstore": ... } }.
# Absent, the single-locale store-notes.txt is still a correct answer, so the
# lanes fall back rather than fail.
def store_notes_json
  path = ENV['STORE_NOTES_JSON'].to_s.strip
  return nil if path.empty? || !File.exist?(path)

  JSON.parse(File.read(path))
rescue JSON::ParserError => e
  UI.user_error!("#{path} is not valid JSON: #{e.message}")
end

def locale_store_notes(locale, kind, limit, notes_json = store_notes_json)
  text = notes_json&.dig(locale, kind.to_s).to_s.strip
  if text.empty?
    # The fallback needs the single-locale file. Say so with the runbook pointer
    # every other missing input here gets, rather than a bare KeyError.
    require_env!(%w[STORE_NOTES_FILE])
    return store_notes(limit)
  end
  truncate_store_text(text, limit)
end

# Writes the release notes every store reads out of its metadata tree. deliver
# takes `<locale>/release_notes.txt`; supply takes
# `<locale>/changelogs/<versionCode>.txt`. Returns the paths written so a lane
# can log exactly what a submission will carry.
def write_release_notes!(metadata_path, kind:, limit:, changelog_name: nil)
  notes_json = store_notes_json
  locales = metadata_locales(metadata_path)
  # An empty locale list writes nothing and returns [], which reads exactly like
  # a successful run: `release_production` would go on to submit for review with
  # no release notes at all. An empty tree, or a path that resolved somewhere
  # else, is a mistake, and this is the last moment anyone can be told.
  assert_metadata_locales!(metadata_path, locales)
  locales.map do |locale|
    text = locale_store_notes(locale, kind, limit, notes_json)
    path =
      if changelog_name
        File.join(metadata_path, locale, 'changelogs', changelog_name)
      else
        File.join(metadata_path, locale, 'release_notes.txt')
      end
    # A rehearsal must not leave modified files behind in a working tree: the
    # whole point of DRY_RUN=1 is that it can be run on a laptop.
    if ENV['DRY_RUN'] == '1'
      UI.important("[dry-run] would write #{path} (#{text.length} chars)")
    else
      require 'fileutils'
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "#{text}\n")
    end
    path
  end
end

# The template ships prose that says "Replace this text ...". Shipping it to
# App Review or to Play is worse than failing the lane, and production
# submission is the last moment anyone can still be told.
METADATA_PLACEHOLDER = 'Replace this text'

# A metadata tree with no locale directories in it. Every caller of this and of
# `write_release_notes!` would otherwise pass silently on a tree that is empty
# or, more likely, on a path that resolved to the wrong place.
def assert_metadata_locales!(metadata_path, locales = metadata_locales(metadata_path))
  return unless locales.empty?

  UI.user_error!("No locale directories under #{metadata_path} — store metadata is missing or the path is wrong (see the release runbook)")
end

def assert_metadata_ready!(metadata_path)
  assert_metadata_locales!(metadata_path)
  offenders = Dir.glob(File.join(metadata_path, '**', '*.txt')).sort.select do |file|
    File.read(file).include?(METADATA_PLACEHOLDER)
  end
  return if offenders.empty?

  UI.user_error!("Store metadata still contains template placeholder text: #{offenders.join(', ')} (see the release runbook)")
end

# deliver rejects a directory under metadata_path that is neither an Apple
# locale nor one of its own special folders, *before* it uploads anything
# (deliver/lib/deliver/loader.rb:167) - and its error lists every locale Apple
# supports, which buries the one useful fact. Say it here instead. This is why
# iOS screenshots live in fastlane/screenshots/<locale>/, deliver's own
# default: `screenshots` is exactly the directory name that trips it.
#
# The list is deliver's own EXCEPTION_DIRECTORIES (deliver/lib/deliver/
# loader.rb:19-24) plus the three folders it treats as language folders of
# their own (`default`, `appleTV`, `iMessage`). The comparison is
# case-insensitive because deliver's is: LanguageFolder#valid? downcases the
# directory name before matching, so an `appletv` or `Review_Information` that
# deliver accepts must not be refused here.
IOS_METADATA_ALLOWED_DIRS = %w[
  review_information trade_representative_contact_information
  app_clip_review_information default fonts appleTV iMessage android
].freeze
IOS_METADATA_ALLOWED_DIRS_DOWNCASED = IOS_METADATA_ALLOWED_DIRS.map(&:downcase).freeze

def assert_ios_metadata_dirs!(metadata_path)
  offenders = Dir.children(metadata_path).select do |name|
    File.directory?(File.join(metadata_path, name)) &&
      !LOCALE_DIR_PATTERN.match?(name) && !IOS_METADATA_ALLOWED_DIRS_DOWNCASED.include?(name.downcase)
  end
  return if offenders.empty?

  UI.user_error!(
    "#{metadata_path} holds directories deliver will reject: #{offenders.sort.join(', ')} - " \
    'screenshots belong in fastlane/screenshots/<locale>/ (see the release runbook)'
  )
end

# ---------- store listing sync (fastlane/metadata/** -> the consoles) -------
#
# The sync lanes push the *baseline* listing at any time, independent of a
# release. What a release owns and this must never touch: the per-version
# release notes (write_release_notes!), the binary, the review submission, the
# Play track. Both consoles are told only what the repository holds, and the
# repository holds only what a diff has been reviewed for.

# The repository variable that arms the push lanes, checked before anything
# else in them. Off by default and refused loudly: every other tier in this
# repo works that way (STORE_UPLOADS_ENABLED, IOS_SIGNING_ENABLED), and a
# consumer who has not opted in must not be able to overwrite a live store
# page by running a lane whose name looks harmless.
def assert_metadata_sync_enabled!
  return if truthy?(ENV['STORE_METADATA_SYNC_ENABLED'])

  UI.user_error!(
    'Store listing sync is off: set the repository variable ' \
    'STORE_METADATA_SYNC_ENABLED=true (or export it locally) before a lane may ' \
    'write the public store page (see the release runbook)'
  )
end

# deliver and supply upload whatever is on disk under metadata_path, so the
# only way to withhold a file from them is not to show it to them: the push
# lanes run against a staged copy of the tree with the per-version paths
# removed. Copying rather than deleting also means a lane can never damage the
# working tree of the checkout it runs in.
def assert_huawei_uploads_enabled!
  return if truthy?(ENV['HUAWEI_UPLOADS_ENABLED'])

  UI.user_error!(
    'Huawei AppGallery uploads are off: set the repository variable ' \
    'HUAWEI_UPLOADS_ENABLED=true (or export it locally) before a lane may ' \
    'publish to AppGallery (see the release runbook)'
  )
end

SYNC_EXCLUDED_FILES = %w[release_notes.txt].freeze
SYNC_EXCLUDED_DIRS = %w[changelogs].freeze

def with_baseline_metadata(source, exclude_files: SYNC_EXCLUDED_FILES, exclude_dirs: SYNC_EXCLUDED_DIRS)
  require 'tmpdir'
  require 'fileutils'
  Dir.mktmpdir('store-metadata-sync') do |tmp|
    staged = File.join(tmp, File.basename(source))
    FileUtils.cp_r(source, staged)
    exclude_dirs.each { |name| Dir.glob(File.join(staged, '**', name)).each { |dir| FileUtils.rm_rf(dir) } }
    exclude_files.each { |name| Dir.glob(File.join(staged, '**', name)).each { |file| FileUtils.rm_f(file) } }
    # supply reads a listing field by file existence: it assigns
    # `File.read(path)` whenever the file is there (supply/lib/supply/
    # uploader.rb:269-271), so a zero-byte file PATCHes an empty value and
    # clears whatever the console already holds. (deliver is the kinder of the
    # two -- it skips an empty value, upload_metadata.rb:151 and :177 -- but
    # the tree is staged the same way for both.) A consumer who wants to blank
    # a field does it in the console, not by shipping an empty template file.
    Dir.glob(File.join(staged, '**', '*.txt')).each { |file| FileUtils.rm_f(file) if File.zero?(file) }
    UI.message("Staged baseline metadata at #{staged} (excluded: #{(exclude_files + exclude_dirs).join(', ')})")
    yield staged
  end
end

def ios_screenshots_path
  fastlane_path('screenshots')
end

# Whether there is anything to upload. Asked before skip_screenshots is
# cleared, because deliver's screenshot upload demands an edit version even
# when it would find no files (deliver/lib/deliver/upload_screenshots.rb:22).
IOS_SCREENSHOT_EXTENSIONS = %w[.png .jpg .jpeg].freeze

# Dir.glob ignores File::FNM_CASEFOLD on a case-sensitive filesystem, so a
# `*.png` glob that matched `01.PNG` on macOS matched nothing on the Linux
# runner. The extension is compared after downcasing instead.
def ios_screenshots?
  Dir.glob(File.join(ios_screenshots_path, '*', '*')).any? do |file|
    File.file?(file) && IOS_SCREENSHOT_EXTENSIONS.include?(File.extname(file).downcase)
  end
end

def ios_app_rating_config_path(metadata_path)
  path = File.join(metadata_path, 'app_rating_config.json')
  File.exist?(path) ? path : nil
end

# supply attaches a listing edit to a release: perform_upload_meta looks up a
# track and a release for a version code before it writes a single listing
# field, and errors out if it finds neither (supply/lib/supply/uploader.rb:84).
# So a listing-only sync still has to name the release it rides on. It changes
# nothing about it - no binary, no rollout, no promotion.
PLAY_METADATA_TRACKS = %w[production beta internal].freeze

def play_metadata_target
  package = ENV.fetch('ANDROID_PACKAGE')
  configured = ENV['PLAY_METADATA_TRACK'].to_s.strip
  tracks = configured.empty? ? PLAY_METADATA_TRACKS : [configured]

  tracks.each do |track|
    codes = Array(store_action(:google_play_track_version_codes,
                               package_name: package, track: track, **play_json_key_args))
    next if codes.empty?

    return [track, codes.map(&:to_i).max]
  end

  # DRY_RUN returns [] for every track, so a rehearsal would otherwise stop
  # with a store-shaped error it cannot answer.
  return ['production', ENV.fetch('APP_BUILD_NUMBER').to_i] if ENV['DRY_RUN'] == '1'

  UI.user_error!(
    "Play has no release on #{tracks.join(', ')} for #{package}: upload a build first " \
    '(`fastlane android upload_internal`), or set PLAY_METADATA_TRACK (see the release runbook)'
  )
end

# The App Store Connect key as deliver's *command line* wants it: a JSON file.
# The lanes hand the key to actions as a hash, but `deliver download_metadata`
# is a fastlane command, not an action, so it runs in its own process with its
# own configuration. 0600 in a temp dir, and never an argument: an argv is
# world-readable (same reason as with_password_files in android.rb).
def with_asc_api_key_file
  require 'tmpdir'
  require 'json'
  require_env!(%w[ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8_BASE64])
  Dir.mktmpdir('asc-api-key') do |dir|
    path = File.join(dir, 'key.json')
    File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write(JSON.generate(
                   key_id: ENV.fetch('ASC_KEY_ID'),
                   issuer_id: ENV.fetch('ASC_ISSUER_ID'),
                   key: ENV.fetch('ASC_KEY_P8_BASE64'),
                   is_key_content_base64: true,
                   in_house: false
                 ))
    end
    yield path
  end
end

# The same, for supply's command line: `--json_key <path>`.
def with_play_json_key_file
  args = play_json_key_args
  return yield(args[:json_key]) if args[:json_key]

  require 'tmpdir'
  Dir.mktmpdir('play-json-key') do |dir|
    path = File.join(dir, 'key.json')
    File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |f| f.write(args.fetch(:json_key_data)) }
    yield path
  end
end

# A pull overwrites files a human wrote. Say so before, and show the damage
# after: `git diff` in the run log is the whole review surface when the pull
# ran in CI, where nothing can be committed.
def warn_metadata_overwrite!(relative_path)
  UI.important("This overwrites #{relative_path}/** with what the console holds. " \
               'Review `git diff` before committing: the console, not this tree, wrote these files.')
end

# Returns the argv, it does not run it: this file is loaded standalone by the
# tests, without fastlane, and its header forbids `sh` here -- the pull lanes
# are the ones that run these through `sh`.
#
# `-C <repo root>` and absolute pathspecs, not repo-root-relative ones: git
# resolves a pathspec against the process's working directory, and fastlane
# runs every lane from `fastlane/` (fastlane/lib/fastlane/runner.rb:42-45, and
# see `repo_root` above). A `--porcelain -- fastlane/metadata/ios` issued from
# there matches nothing and exits 0, so a pull that rewrote the whole tree
# would report no changes at all. Callers pass `root_path(...)` values.
def metadata_diff_commands(*paths)
  root = repo_root
  [
    ['git', '-C', root, 'status', '--porcelain', '--', *paths],
    ['git', '-C', root, '--no-pager', 'diff', '--stat', '--', *paths]
  ]
end
