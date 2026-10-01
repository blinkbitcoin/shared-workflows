// The job graphs of the four pipeline workflows, decided the way GitHub decides
// them (test/lib/workflow-graph.mjs). The shape of each file is held by
// workflow-shape.bats; this is what the graph does with a failed, skipped or
// switched-off job, which nothing in the shape of a `needs:` list shows: a
// `needs:` looks the same whether or not it silently blocks half a pipeline.
import assert from 'node:assert/strict';
import path from 'node:path';
import test, { describe } from 'node:test';
import { fileURLToPath } from 'node:url';
import { loadWorkflow, run, translate, unwrap } from './lib/workflow-graph.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
const workflow = (name) => loadWorkflow(path.join(root, '.github', 'workflows', `${name}.yml`));

/** The jobs of `results` that ran, in the order they were decided. */
const ran = (results) => Object.keys(results).filter((job) => results[job] !== 'skipped');

describe('the evaluator', () => {
  test('reads a status function, an input comparison and a list lookup', () => {
    assert.equal(unwrap("${{ !failure() && inputs.action == 'release' }}"), "!failure() && inputs.action == 'release'");
    assert.equal(unwrap('inputs.x'), 'inputs.x');
    assert.match(translate(`contains(fromJSON('["halt", "resume"]'), inputs.action)`), /\["halt", "resume"\]\.includes\(inputs\["action"\]\)/);
  });

  test('refuses a term it cannot evaluate, rather than evaluating it wrongly', () => {
    assert.throws(() => translate('github.event_name == 1'), /cannot evaluate/);
  });
});

describe('publish-internal.yml', () => {
  const internal = workflow('publish-internal');
  const stores = { 'store-uploads-enabled': true };

  test('with store uploads on, everything but Huawei and OTA runs', () => {
    const results = run(internal, { inputs: stores });
    assert.deepEqual(ran(results), ['prepare', 'build-ios', 'build-android', 'upload-ios', 'upload-android', 'github-prerelease']);
  });

  test('Huawei needs both toggles, and OTA its own', () => {
    const only = run(internal, { inputs: { ...stores, 'huawei-uploads-enabled': true, 'ota-enabled': true } });
    assert.equal(only['upload-huawei'], 'success');
    assert.equal(only['ota-internal'], 'success');
    assert.equal(run(internal, { inputs: { 'huawei-uploads-enabled': true } })['upload-huawei'], 'skipped');
    assert.equal(run(internal, { inputs: { ...stores } })['upload-huawei'], 'skipped');
  });

  test('with store uploads off, nothing is uploaded and the pre-release is still published', () => {
    const results = run(internal);
    assert.deepEqual(ran(results), ['prepare', 'build-ios', 'build-android', 'github-prerelease']);
  });

  test('a build that failed or timed out holds the pre-release back', () => {
    for (const outcome of ['failure', 'cancelled']) {
      const results = run(internal, { inputs: stores, outcome: { 'build-android': outcome } });
      assert.equal(results['github-prerelease'], 'skipped', `build-android ${outcome}`);
      assert.equal(results['upload-android'], 'skipped', `build-android ${outcome}`);
    }
  });

  test('Huawei, which has a review queue that is not ours, never holds the pre-release back', () => {
    const results = run(internal, { inputs: { ...stores, 'huawei-uploads-enabled': true }, outcome: { 'upload-huawei': 'failure' } });
    assert.equal(results['github-prerelease'], 'success');
    assert.ok(!internal.jobs['github-prerelease'].needs.includes('upload-huawei'));
  });

  test('AppGallery never receives a build Play refused', () => {
    const results = run(internal, { inputs: { ...stores, 'huawei-uploads-enabled': true }, outcome: { 'upload-android': 'failure' } });
    assert.equal(results['upload-huawei'], 'skipped');
  });

  test('every store job joins the shared release queue on its own', () => {
    for (const job of ['upload-ios', 'upload-android', 'upload-huawei', 'ota-internal']) {
      assert.deepEqual(internal.jobs[job].concurrency, { group: 'release', 'cancel-in-progress': false }, job);
    }
    assert.equal(internal.concurrency, undefined);
  });

  test('a failed prepare, which includes a red green gate, stops everything', () => {
    const results = run(internal, { inputs: { ...stores, 'ota-enabled': true }, outcome: { prepare: 'failure' } });
    assert.deepEqual(ran(results), ['prepare']);
  });
});

describe('publish-beta.yml', () => {
  const beta = workflow('publish-beta');
  const stores = { 'store-uploads-enabled': true };

  test('promotes both stores, releases, attaches the notes, and Huawei and OTA only when switched on', () => {
    assert.deepEqual(ran(run(beta, { inputs: stores })), ['prepare', 'promote-ios', 'promote-android', 'github-release', 'store-notes']);
    const all = run(beta, { inputs: { ...stores, 'huawei-uploads-enabled': true, 'ota-enabled': true } });
    assert.deepEqual(ran(all), ['prepare', 'promote-ios', 'promote-android', 'github-release', 'promote-huawei', 'store-notes', 'ota-beta']);
  });

  test('with store uploads off the release is still moved and the notes attached', () => {
    assert.deepEqual(ran(run(beta)), ['prepare', 'github-release', 'store-notes']);
  });

  test('a promotion that failed stops the release, the notes and OTA, and Huawei', () => {
    const results = run(beta, {
      inputs: { ...stores, 'huawei-uploads-enabled': true, 'ota-enabled': true },
      outcome: { 'promote-android': 'failure' },
    });
    for (const job of ['github-release', 'store-notes', 'ota-beta', 'promote-huawei']) assert.equal(results[job], 'skipped', job);
  });

  test('Huawei is behind both toggles', () => {
    assert.equal(run(beta, { inputs: { 'huawei-uploads-enabled': true } })['promote-huawei'], 'skipped');
    assert.equal(run(beta, { inputs: stores })['promote-huawei'], 'skipped');
  });

  test('a failed Huawei promotion does not hold up the notes or OTA, which do not wait for it', () => {
    const results = run(beta, {
      inputs: { ...stores, 'huawei-uploads-enabled': true, 'ota-enabled': true },
      outcome: { 'promote-huawei': 'failure' },
    });
    assert.equal(results['store-notes'], 'success');
    assert.equal(results['ota-beta'], 'success');
  });

  test('the Huawei lane gets the bundle from the release tag and nothing else stages it', () => {
    const huawei = beta.jobs['promote-huawei'].with;
    assert.equal(huawei['release-assets'], '*.aab');
    assert.equal(huawei['release-tag'], '${{ inputs.tag }}');
    assert.ok(Object.values(beta.jobs).every((job) => job.uses), 'every job calls a workflow');
  });

  test('prepare asks for the green gate and dispatches the build once when it is missing', () => {
    const prepare = beta.jobs.prepare.with;
    assert.equal(prepare['require-green-dispatch'], true);
    assert.equal(prepare['release-tag'], '${{ inputs.tag }}');
    assert.equal(beta.jobs.prepare.permissions.actions, 'write');
  });
});

describe('publish-production.yml', () => {
  const production = workflow('publish-production');
  const stores = { 'store-uploads-enabled': true };
  const release = { ...stores, action: 'release' };

  test('a release runs security, then both stores, then the release, the stage note and the web site', () => {
    const results = run(production, { inputs: { ...release, web: true, 'ota-enabled': true } });
    assert.deepEqual(ran(results), [
      'prepare',
      'security',
      'ios-release',
      'android-release',
      'github-release',
      'stage-append',
      'ota-production',
      'web',
    ]);
  });

  test('a failed security gate stops every release, and the release itself', () => {
    const results = run(production, { inputs: { ...release, 'huawei-uploads-enabled': true }, outcome: { security: 'failure' } });
    for (const job of ['ios-release', 'android-release', 'huawei-release', 'github-release']) assert.equal(results[job], 'skipped', job);
  });

  test('a gate that is switched off is skipped, and does not skip the release with it', () => {
    const results = run(production, { inputs: { ...release, 'security-enabled': false } });
    assert.equal(results.security, 'skipped');
    for (const job of ['ios-release', 'android-release', 'github-release']) assert.equal(results[job], 'success', job);
  });

  test('Huawei waits on Android, so the gate holds it too', () => {
    const on = { ...release, 'huawei-uploads-enabled': true };
    assert.equal(run(production, { inputs: on })['huawei-release'], 'success');
    assert.equal(run(production, { inputs: on, outcome: { 'android-release': 'failure' } })['huawei-release'], 'skipped');
    assert.equal(run(production, { inputs: { ...on, platforms: 'ios' } })['huawei-release'], 'skipped');
  });

  test('platforms narrows the stores, never the release', () => {
    const ios = run(production, { inputs: { ...release, platforms: 'ios' } });
    assert.deepEqual([ios['ios-release'], ios['android-release']], ['success', 'skipped']);
    assert.equal(ios['github-release'], 'success');
    const android = run(production, { inputs: { ...release, platforms: 'android' } });
    assert.deepEqual([android['ios-release'], android['android-release']], ['skipped', 'success']);
  });

  test('halt pauses iOS and halts Android, and moves nothing else', () => {
    const results = run(production, { inputs: { ...stores, action: 'halt' } });
    assert.deepEqual(ran(results), ['prepare', 'ios-phased', 'android-halt', 'stage-append']);
  });

  test('rollout moves only Android, resume moves both, complete moves both', () => {
    const rollout = run(production, { inputs: { ...stores, action: 'rollout' } });
    assert.deepEqual(ran(rollout), ['prepare', 'android-rollout', 'stage-append']);
    for (const action of ['resume', 'complete']) {
      assert.deepEqual(ran(run(production, { inputs: { ...stores, action } })), ['prepare', 'ios-phased', 'android-rollout', 'stage-append'], action);
    }
  });

  test('a rollout change runs no security gate, no release, no OTA and no web deploy', () => {
    for (const action of ['rollout', 'halt', 'resume', 'complete']) {
      const results = run(production, { inputs: { ...stores, action, web: true, 'ota-enabled': true } });
      for (const job of ['security', 'github-release', 'ota-production', 'web']) assert.equal(results[job], 'skipped', `${action} ${job}`);
    }
  });

  test('with store uploads off nothing reaches a store, and the release is still marked', () => {
    const results = run(production, { inputs: { action: 'release' } });
    assert.deepEqual(ran(results), ['prepare', 'security', 'github-release', 'stage-append']);
  });

  test('the stage note survives a skipped store job, and a failed one', () => {
    assert.equal(run(production, { inputs: { ...stores, action: 'halt' } })['stage-append'], 'success');
    assert.equal(run(production, { inputs: release, outcome: { 'android-release': 'failure' } })['stage-append'], 'skipped');
  });

  test('the web site is behind its own input, after the release', () => {
    assert.equal(run(production, { inputs: release })['web'], 'skipped');
    assert.equal(run(production, { inputs: { ...release, web: true } })['web'], 'success');
    assert.ok(production.jobs.web.needs.includes('github-release'));
  });

  test('the security gate runs only the binary-side scanners and never an LLM', () => {
    const security = production.jobs.security.with;
    assert.deepEqual([security.binaries, security.mobile, security.bundle, security.sbom], [true, true, true, true]);
    assert.deepEqual([security.dependencies, security.code, security.policy], [false, false, false]);
    assert.doesNotMatch(JSON.stringify(security), /review/i);
    assert.doesNotMatch(JSON.stringify(production), /OPENAI|ANTHROPIC/);
  });

  test('a cancelled run starts no job, not even one whose only gate is its needs', () => {
    const results = run(production, { inputs: release, cancelled: true });
    assert.deepEqual(ran(results), []);
  });
});

describe('publish-store-listing.yml', () => {
  const listing = workflow('publish-store-listing');

  test('does nothing unless the sync is switched on', () => {
    assert.deepEqual(ran(run(listing)), []);
  });

  test('both platforms by default, one when asked', () => {
    const on = { 'store-metadata-sync-enabled': true };
    assert.deepEqual(ran(run(listing, { inputs: on })), ['ios', 'android']);
    assert.deepEqual(ran(run(listing, { inputs: { ...on, platforms: 'ios' } })), ['ios']);
    assert.deepEqual(ran(run(listing, { inputs: { ...on, platforms: 'android' } })), ['android']);
  });

  test('a dry run is the default, so a mistaken dispatch changes nothing', () => {
    assert.equal(listing.on.workflow_call.inputs['dry-run'].default, true);
    assert.equal(listing.on.workflow_call.inputs['store-metadata-sync-enabled'].default, false);
  });
});

describe('every pipeline', () => {
  const names = ['publish-internal', 'publish-beta', 'publish-production', 'publish-store-listing'];

  test('is made only of calls to this repository’s own workflows, with no step of its own', () => {
    for (const name of names) {
      for (const [job, spec] of Object.entries(workflow(name).jobs)) {
        assert.match(spec.uses, /^\.\/\.github\/workflows\/[a-z-]+\.yml$/, `${name}: ${job}`);
        assert.equal(spec.steps, undefined, `${name}: ${job}`);
      }
    }
  });

  test('declares every secret optional, and reads no repository variable', () => {
    for (const name of names) {
      const spec = workflow(name);
      for (const [secret, def] of Object.entries(spec.on.workflow_call.secrets)) {
        assert.equal(def.required, false, `${name}: ${secret}`);
      }
      assert.doesNotMatch(JSON.stringify(spec.jobs), /\bvars\./, `${name} reads a repository variable`);
    }
  });

  test('holds contents: read at the top and names no concurrency group for its caller', () => {
    for (const name of names) {
      const spec = workflow(name);
      assert.equal(spec.permissions.contents, 'read', name);
      assert.equal(spec.concurrency, undefined, name);
    }
  });
});
