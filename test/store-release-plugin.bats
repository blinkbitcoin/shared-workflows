#!/usr/bin/env bats
# The store-release plugin (plugins/store-release): the marketplace that offers
# it, the manifest, the shape of each skill, and each skill's own offline suite.
#
# The suites run against fakes (`gh`, `bundle`) and scratch repositories, no
# network. They also compare lists with an app's lanes and the fastlane gem when
# they can find them (APP_REPO_ROOT, or the shipped lanes and `.gems/` of this
# repository) and say SKIP, by name, when they cannot; see each suite's header.
#
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper

PLUGIN="plugins/store-release"
SKILLS="store-setup store-consoles store-credentials store-metadata"

setup() {
  cd "$REPO_ROOT" || return 1
}

@test "the marketplace offers store-release from the directory that holds it" {
  run node -e '
    const fs = require("fs");
    const market = JSON.parse(fs.readFileSync(".claude-plugin/marketplace.json", "utf8"));
    const entry = market.plugins.find((p) => p.name === "store-release");
    if (!entry) throw new Error("no store-release entry");
    if (entry.source !== "./plugins/store-release") throw new Error(`source is ${entry.source}`);
    const manifest = JSON.parse(fs.readFileSync(`${entry.source}/.claude-plugin/plugin.json`, "utf8"));
    if (manifest.name !== entry.name) throw new Error(`plugin.json is named ${manifest.name}`);
    if (!market.owner || !market.owner.name) throw new Error("no owner");
  '
  [ "$status" -eq 0 ] || fail "$output"
}

@test "the plugin ships exactly the four store skills, each named for its directory" {
  [ "$(ls "$PLUGIN/skills" | tr '\n' ' ')" = "store-consoles store-credentials store-metadata store-setup " ] \
    || fail "skills: $(ls "$PLUGIN/skills")"
  for skill in $SKILLS; do
    file="$PLUGIN/skills/$skill/SKILL.md"
    [ -f "$file" ] || fail "no $file"
    [ "$(sed -n 's/^name: //p' "$file" | head -1)" = "$skill" ] || fail "$file is not named $skill"
    grep -q '^description: Use when ' "$file" || fail "$file has no 'Use when' description"
    grep -q '^allowed-tools: ' "$file" || fail "$file has no allowed-tools"
  done
}

@test "no skill file still names the repository path it was copied from" {
  run grep -rn -F '.claude/skills' "$PLUGIN"
  [ "$status" -ne 0 ] || fail "found the old path: $output"
}

@test "every script a skill allows is under the plugin root and exists" {
  for skill in $SKILLS; do
    file="$PLUGIN/skills/$skill/SKILL.md"
    allowed="$(sed -n 's/^allowed-tools: //p' "$file" | head -1)"
    while IFS= read -r entry; do
      case "$entry" in
        *'${CLAUDE_PLUGIN_ROOT}'*)
          path="${entry#*'${CLAUDE_PLUGIN_ROOT}/'}"
          path="${path%%:\**}"
          [ -f "$PLUGIN/$path" ] || fail "$skill allows $entry, but $PLUGIN/$path does not exist"
          ;;
        *.claude/skills*) fail "$skill allows a repository path: $entry" ;;
      esac
    done < <(printf '%s' "$allowed" | tr ',' '\n' | sed 's/^ *//')
  done
}

@test "the skills run state.sh and each other's scripts through the plugin root" {
  # A bare `state.sh next` would run whatever is on PATH, or nothing: the path a
  # skill is told to run must be the one inside the plugin.
  run grep -rnE '(^|[^/}a-z.-])state\.sh (next|set|note|render|init|mode|--list-steps)' "$PLUGIN/skills" --include='*.md'
  [ "$status" -ne 0 ] || fail "a bare state.sh invocation: $output"
}

@test "claude plugin validate accepts the marketplace and the plugin" {
  command -v claude >/dev/null 2>&1 || skip "claude is not installed"
  run claude plugin validate .
  [ "$status" -eq 0 ] || fail "marketplace: $output"
  run claude plugin validate "$PLUGIN"
  [ "$status" -eq 0 ] || fail "plugin: $output"
}

@test "the store-setup suite passes" {
  run bash "$PLUGIN/skills/store-setup/tests/run.sh"
  [ "$status" -eq 0 ] || fail "$output"
}

@test "the store-consoles suite passes" {
  run bash "$PLUGIN/skills/store-consoles/tests/run.sh"
  [ "$status" -eq 0 ] || fail "$output"
}

@test "the store-credentials suite passes" {
  run bash "$PLUGIN/skills/store-credentials/tests/run.sh"
  [ "$status" -eq 0 ] || fail "$output"
}

@test "the store-metadata suite passes" {
  run bash "$PLUGIN/skills/store-metadata/tests/run.sh"
  [ "$status" -eq 0 ] || fail "$output"
}
