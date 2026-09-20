import assert from 'node:assert/strict';
import {test} from 'node:test';
import {fuzzyScore, rankTargets, buildIdTree, filterIdTree, expandIdPath} from '../src/assets/find.mjs';

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

const target = (label, path = 'docs/S00.11-worker.md', id = label) => ({label, path, id, url: '/' + path + '#' + encodeURIComponent(id)});
const flatten = tree => tree.flatMap(node => [node, ...flatten(node.children)]);

test('ID tree links phase, spec, task and example across prefixes, sorting numbers naturally', () => {
  const targets = [
    target('E0.11.2.1'), target('[x] T0.11.2 run worker'), target('S0.11 worker'),
    target('S0.10 tenth', 'docs/S00.10-tenth.md'), target('S0.2 second', 'docs/S00.02-second.md'),
    target('P0 bootstrap', 'docs/P00-bootstrap.md'), target('S0.11.10 later'), target('S0.11.2 earlier'),
  ];
  const tree = buildIdTree(targets);
  const phase = tree[0].children[0];
  assert.equal(tree[0].title, 'Specs');
  assert.equal(phase.code, 'P0');
  assert.deepEqual(phase.children.map(node => node.code), ['S0.2', 'S0.10', 'S0.11']);
  const spec = phase.children[2];
  assert.deepEqual(spec.children.map(node => node.code), ['S0.11.2', 'S0.11.10', 'T0.11.2']);
  assert.equal(spec.children[2].children[0].code, 'E0.11.2.1');
  assert.equal(flatten(tree).filter(node => node.target).length, targets.length);
});

test('core docs retain file context, out-of-order ID parents and duplicate destinations', () => {
  const targets = [target('R1.2 form', 'docs/rules.md'), target('R1 writing', 'docs/rules.md'),
    target('R1 writing', 'AGENTS.md'), target('Introduction', 'README.md'),
    target('S0.11 worker'), target('S0.11 worker', 'docs/S00.11-worker.md', 'alternate')];
  const tree = buildIdTree(targets);
  assert.deepEqual(tree.map(node => node.title), ['Core docs', 'Specs']);
  const parent = flatten(tree).find(node => node.code === 'R1' && node.target.path === 'docs/rules.md');
  assert.equal(parent.children[0].code, 'R1.2');
  assert.equal(flatten(tree).filter(node => node.target).length, targets.length);
});

test('tree search retains ancestors, hides unrelated siblings and leaves the original tree unchanged', () => {
  const targets = [target('P0 bootstrap', 'docs/P00-bootstrap.md'), target('S0.11 worker'),
    target('T0.11.1 launch'), target('E0.11.1.1 success'), target('E0.11.1.2 failure'),
    target('S0.2 read', 'docs/S00.02-read.md')];
  const tree = buildIdTree(targets);
  const before = JSON.stringify(tree);
  const filtered = filterIdTree(tree, 'success');
  assert.deepEqual(flatten(filtered).map(node => node.code || node.title), ['Specs', 'P0', 'S0.11', 'T0.11.1', 'E0.11.1.1']);
  assert.equal(flatten(filtered).filter(node => node.directMatch).length, 1);
  assert.deepEqual(filterIdTree(tree, 'missing'), []);
  assert.equal(filterIdTree(tree, '  '), tree);
  assert.equal(JSON.stringify(tree), before);
  assert.equal(flatten(filterIdTree(tree, 'worker success')).at(-1).code, 'E0.11.1.1');
});

test('missing parents are navigable branches without invented destinations', () => {
  const tree = buildIdTree([target('E2.10.3.1 proof', 'docs/S02.10-check.md')]);
  assert.deepEqual(flatten(tree).map(node => node.code || node.title), ['Specs', 'P2', 'S2.10', 'T2.10.3', 'E2.10.3.1']);
  assert.equal(flatten(tree).filter(node => node.target).length, 1);
});

test('exact IDs select their definition ahead of earlier references and longer IDs in the tree', () => {
  const reference = target('W1 links S1.6', 'docs/03-workflow.md');
  const child = target('S1.6.1 constraints', 'docs/S01.06-authority-trace.md');
  const spec = target('S1.6 authority trace', 'docs/S01.06-authority-trace.md', 's16-authority-trace');
  const task = target('[x] T1.6.1 implement', 'docs/S01.06-authority-trace.md');
  const targets = [reference, child, task, spec];
  const tree = buildIdTree(targets);
  for (const query of ['s1.6', ' S1.6 ', 's01.06']) {
    assert.equal(rankTargets(targets, query)[0], spec);
    const nodes = flatten(filterIdTree(tree, query));
    assert.equal(nodes.find(node => node.bestMatch).target, spec);
    assert.ok(nodes.some(node => node.target === child));
    assert.equal(nodes[0].title, 'Core docs'); // Selection does not reorder the tree.
  }
  assert.equal(flatten(filterIdTree(tree, 't1.6.1')).find(node => node.bestMatch).target, task);
  assert.equal(flatten(filterIdTree(tree, 'constraints')).find(node => node.bestMatch).target, child);
});


test('leaving ID search opens the selected branch and its ancestors without changing other branches', () => {
  const tree = buildIdTree([target('S1.6 authority trace', 'docs/S01.06-trace.md'),
    target('T1.6.1 implement', 'docs/S01.06-trace.md'),
    target('E1.6.1.1 proof', 'docs/S01.06-trace.md'),
    target('S1.7 other', 'docs/S01.07-other.md')]);
  const expanded = new Set(['core', 'unrelated']);
  assert.equal(expandIdPath(tree, 'S1.6', expanded), true);
  assert.deepEqual([...expanded].sort(), ['P1', 'S1.6', 'core', 'specs', 'unrelated']);
  assert.equal(expandIdPath(tree, 'E1.6.1.1', expanded), true);
  assert.ok(expanded.has('T1.6.1'));
  const before = [...expanded];
  assert.equal(expandIdPath(tree, 'missing', expanded), false);
  assert.deepEqual([...expanded], before);
});
