# Enough of fastlane to load fastlane/lanes/*.rb without fastlane running.
#
# shared.rb is deliberately written against `UI` and plain Ruby only, and the
# lane files use nothing but the `platform`/`lane`/`desc` DSL plus fastlane
# actions -- so the helpers and the promotion logic that decide what gets
# uploaded can be unit-tested in milliseconds instead of being discovered
# during a release.
require 'json'

# Records every stubbed fastlane action call as [name, args].
$calls = []

# Per-test overrides for what a stubbed action returns, so a test can say
# "TestFlight already has build 42" without redefining the stub.
$stub_results = {}

# One entry per stubbed action call that carries a metadata_path: the sorted,
# relative file list staged at call time.
$metadata_snapshots = []

# Recorded next to the arguments: a lane that stages a copy of the metadata
# tree deletes it the moment the action returns, so the tree's *contents* at
# call time are observable only from inside the stub.
def snapshot_metadata!(args)
  path = args[:metadata_path]
  return if path.nil? || !Dir.exist?(path.to_s)

  $metadata_snapshots << Dir.glob(File.join(path, '**', '*'))
                            .map { |f| f.delete_prefix("#{path}/") }.sort
end

module UI
  class UserError < StandardError; end

  # fastlane's UI.user_error! aborts the lane; here it just raises.
  def self.user_error!(message)
    raise UserError, message
  end

  def self.important(message)
    messages << message
  end

  def self.message(message)
    messages << message
  end

  def self.success(message)
    messages << message
  end

  def self.messages
    @messages ||= []
  end

  def self.reset!
    messages.clear
  end
end

# Clears the action recorder. Kept separate from UI.reset! so the stubbed UI
# does not own a global it has nothing to do with.
def reset_calls!
  $calls.clear
  $stub_results.clear
  $metadata_snapshots.clear
end

def stub_result(action, value)
  $stub_results[action] = value
end

# The fastlane actions the lanes reach for. Each records its call and returns
# something shaped like the real return value.
#
# These stubs accept any key of any type, which is exactly what makes them
# useless as a check that fastlane will accept the call -- an option renamed by
# a gem bump, or a value of the wrong type, passes here and fails on the first
# real run. `validate_options.rb` is the other half: it replays the recorded
# arguments against the real option definitions. STUBBED_FASTLANE_ACTIONS is how
# a test tells a real action call apart from the `sh`/Spaceship/supply records
# sharing the same list.
STUBBED_FASTLANE_ACTIONS = %i[
  upload_to_testflight upload_to_play_store upload_to_app_store gym gradle match
  setup_ci app_store_connect_api_key google_play_track_version_codes
  latest_testflight_build_number get_version_number get_build_number
  get_info_plist_value download_dsyms increment_version_number increment_build_number
  huawei_appgallery_connect huawei_appgallery_connect_get_app_info
].freeze

{
  upload_to_testflight: nil,
  upload_to_play_store: nil,
  upload_to_app_store: nil,
  gym: '/tmp/App.ipa',
  gradle: '/tmp/app-release.aab',
  match: nil,
  setup_ci: nil,
  app_store_connect_api_key: { key_id: 'STUB' },
  google_play_track_version_codes: [1],
  latest_testflight_build_number: 0,
  get_version_number: '1.2.3',
  get_build_number: '42',
  increment_version_number: nil,
  increment_build_number: nil,
  download_dsyms: nil,
  huawei_appgallery_connect: nil,
  huawei_appgallery_connect_get_app_info: { 'appName' => 'Stub' }
}.each do |action, result|
  Object.send(:define_method, action) do |**args|
    $calls << [action, args]
    snapshot_metadata!(args)
    $stub_results.fetch(action) { result }
  end
end

# fastlane's own answer to "where is the fastlane directory", which repo_root
# is built on: `./fastlane/` from the project root, `.` from inside it (where a
# lane runs), nil anywhere else. A copy of fastlane_core's logic rather than a
# canned value, so a test that changes directory sees what a lane would.
module FastlaneCore
  module FastlaneFolder
    def self.path
      return './fastlane/' if File.directory?('./fastlane/')
      return './.fastlane/' if File.directory?('./.fastlane/')
      return '.' if File.basename(Dir.getwd) == 'fastlane' && File.exist?('Fastfile')

      nil
    end
  end
end

# What a prebuilt Info.plist carries. Keyed by plist key rather than by action
# name: one lane reads two different keys through the same action, and a test
# has to be able to make just one of them disagree.
IOS_INFO_PLIST_STUB = {
  'CFBundleShortVersionString' => '1.2.3',
  'CFBundleVersion' => '42'
}.freeze

def get_info_plist_value(**args)
  $calls << [:get_info_plist_value, args]
  $stub_results.fetch(args[:key].to_sym) { IOS_INFO_PLIST_STUB[args[:key]] }
end

# fastlane's `sh` takes argv plus keyword options (`log:` suppresses the echo
# of a command line that carries a keystore password).
def sh(*command, **options)
  $calls << [:sh, command]
  options
  # bundletool's side effect, not just its argv: `build-apks` writes a zip that
  # the lane immediately opens to extract universal.apk. A stub that records the
  # call and writes nothing makes the unsigned branch untestable, which is part
  # of why it had no coverage.
  stub_bundletool_output(command) if command.include?('build-apks')
  ''
end

def stub_bundletool_output(command)
  output = command.find { |arg| arg.to_s.start_with?('--output=') }
  return if output.nil?

  require 'zip'
  require 'fileutils'
  path = output.to_s.delete_prefix('--output=')
  FileUtils.mkdir_p(File.dirname(path))
  FileUtils.rm_f(path)
  Zip::File.open(path, create: true) do |archive|
    archive.get_output_stream('universal.apk') { |f| f.write('stub apk') }
  end
end

# ---------------------------------------------------------------------------
# The lane DSL
# ---------------------------------------------------------------------------
#
# Loading a lane file records its blocks instead of running them; `run_lane`
# then invokes one with the stubs above in place. This is the only way to test
# the promotion logic itself -- the part that decides `distribute_only`,
# whether to skip an upload, or which fallback to take.

$lanes = {}
$current_platform = nil

def platform(name)
  previous = $current_platform
  $current_platform = name
  yield
ensure
  $current_platform = previous
end

def lane(name, &block)
  ($lanes[$current_platform] ||= {})[name] = block
end

def private_lane(name, &block)
  lane(name, &block)
end

def desc(_text); end

def run_lane(platform_name, lane_name, options = {})
  block = $lanes.fetch(platform_name) { raise "no lanes for platform #{platform_name.inspect}" }
                .fetch(lane_name) { raise "no lane #{lane_name.inspect} on #{platform_name.inspect}" }
  block.call(options)
end

# ---------------------------------------------------------------------------
# Spaceship (iOS `phased`) and supply (Android `halt` fallback)
# ---------------------------------------------------------------------------

module Spaceship
  class ConnectAPI
    class PhasedRelease
      def pause
        $calls << [:phased_release, { action: 'pause' }]
      end

      def resume
        $calls << [:phased_release, { action: 'resume' }]
      end

      def complete
        $calls << [:phased_release, { action: 'complete' }]
      end
    end

    class AppStoreVersion
      def fetch_app_store_version_phased_release
        $stub_results.fetch(:phased_release) { PhasedRelease.new }
      end
    end

    class App
      def self.find(bundle_id)
        $calls << [:spaceship_app_find, { bundle_id: bundle_id }]
        $stub_results.fetch(:spaceship_app) { new }
      end

      def get_live_app_store_version
        $stub_results.fetch(:live_app_store_version) { AppStoreVersion.new }
      end
    end
  end
end

module FastlaneCore
  module Configuration
    def self.create(_options, values)
      values
    end
  end
end

# A supply double. `halt_via_android_publisher!` only requires the real gem when
# `Supply` is undefined, so defining it here keeps the fallback test offline.
module Supply
  module Tracks
    PRODUCTION = 'production'.freeze
  end

  module ReleaseStatus
    HALTED = 'halted'.freeze
  end

  module Options
    def self.available_options
      []
    end
  end

  class << self
    attr_accessor :config
  end

  class Release
    attr_reader :version_codes
    attr_accessor :status

    def initialize(version_codes, status = 'inProgress')
      @version_codes = version_codes
      @status = status
    end
  end

  class Track
    attr_reader :releases

    def initialize(releases)
      @releases = releases
    end
  end

  class Client
    def self.make_from_config
      $calls << [:supply_client, {}]
      new
    end

    def begin_edit(package_name:)
      $calls << [:supply_begin_edit, { package_name: package_name }]
    end

    def tracks(*names)
      $calls << [:supply_tracks, { names: names }]
      $stub_results.fetch(:supply_tracks) { [Track.new([Release.new([42])])] }
    end

    def update_track(name, track)
      $calls << [:supply_update_track, { name: name, statuses: track.releases.map(&:status) }]
    end

    def commit_current_edit!
      $calls << [:supply_commit, {}]
    end
  end
end
