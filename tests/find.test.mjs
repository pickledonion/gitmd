import assert from 'node:assert/strict';
import {test} from 'node:test';
import {fuzzyScore, rankTargets} from '../src/assets/find.mjs';

test('fuzzy matches preserve order and prefer exact, prefix, and contiguous matches', () => {
  assert.equal(fuzzyScore('T-42', 't-42'), 10000);
  assert.equal(fuzzyScore('T-42', '24'), null);
  assert.notEqual(fuzzyScore('Task T-0042', 'tk42'), null);
  assert.ok(fuzzyScore('T42 task', 't42') > fuzzyScore('Task T42', 't42'));
  assert.ok(fuzzyScore('Task T42', 't42') > fuzzyScore('Task T-0042', 't42'));
  assert.equal(fuzzyScore('anything', ''), 0);
});

test('rank paths, heading text and IDs, combining terms across fields', () => {
  const targets = [
    {path: 'tasks.md', label: 'Another task', id: 'task-24'},
    {path: 'specs/worker.md', label: 'Worker retries', id: 'T-42'},
    {path: 'tasks.md', label: 'T42 follow-up', id: 't42-follow-up'},
  ];
  assert.equal(rankTargets(targets, 'T-42')[0], targets[1]);
  assert.deepEqual(rankTargets(targets, 'specs t42'), [targets[1]]);
  assert.deepEqual(rankTargets(targets, 'wrk rt'), [targets[1]]);
  assert.deepEqual(rankTargets(targets, 'no-such-destination'), []);
  assert.deepEqual(rankTargets(targets, '  ', 2), targets.slice(0, 2));
  assert.deepEqual(rankTargets([], 't42'), []);
});
