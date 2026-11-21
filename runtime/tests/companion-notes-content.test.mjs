import assert from 'node:assert/strict';
import {test} from 'node:test';
import {NOTES_LIMITS, notesSystem, selectNotes, notesModelInput, notesInputEstimate,
  readNotesProposal, renderNotesPage} from '../bridge/dsh-go-bridge/lib/companion/notes-content.js';

const directory = {target: {targetKey: '/selected', displayPath: '/selected'}, identity: '1:2'};
const args = {localDate: '2026-11-21', timeZone: 'Asia/Singapore', outputName: '今日待办.md'};
const range = {startAtMs: 1000, endAtMs: 2000};
const file = (name = '日记.md', size = 10, modifiedAtMs = 1500) =>
  ({name, size, modifiedAtMs, identity: '1:3', version: 'opaque-unchanged', type: 'file'});
const select = entries => selectNotes({directory, entries}, args, range, directory, 1700);
const inputs = {directory, scope: {...args, gaps: [], matchedCount: 1}, entries: [
  {name: '日记.md', text: '今天天气不错。\r\n待办：周五配镜，负责人小林。\r\n也许以后可以学画画。\r\n'}]};
const todo = {source: '日记.md', startLine: 2, endLine: 2, quote: '待办：周五配镜，负责人小林。',
  task: '周五配镜', assignee: '小林', due: '周五'};
const parse = value => readNotesProposal(JSON.stringify(value), inputs);

test('SOURCE_UNIT selected original half-open day and same-directory output exclusion', () => {
  const selection = select([file('at-start.md', 5, 1000), file('at-end.md', 5, 2000), file('before.md', 5, 999),
    file('今日待办.md'), {...file('subdir.md'), type: 'directory'}, file('other.pdf')]);
  assert.deepEqual(selection.entries.map(x => x.name), ['at-start.md']);
  assert.deepEqual(selection.scope.gaps, [{name: 'subdir.md', reason: 'not_regular_file'}]);
  assert.equal(selection.scope.selectedAtMs, 1700);
  assert.equal(selection.scope.recursive, false);
});
test('SOURCE_UNIT other output directory does not exclude an input with the same basename', () => {
  const selection = selectNotes({directory, entries: [file('今日待办.md')]}, args, range,
    {...directory, identity: '1:99'}, 1700);
  assert.equal(selection.entries.length, 1);
});
test('SOURCE_UNIT exactly twenty whole inputs accepted and twenty-one refused', () => {
  const entries = Array.from({length: 21}, (_, index) => file(index + '.txt'));
  assert.equal(select(entries.slice(0, 20)).entries.length, 20);
  assert.throws(() => select(entries), {notesReason: 'input_file_count_limit', notesState: 'waiting'});
});
test('SOURCE_UNIT unavailable matching entries remain bounded and cannot become read files', () => {
  const selection = select([file(), {...file('linked.md'), type: 'symlink'}, {name: 'missing.txt', type: 'missing'}]);
  assert.equal(selection.entries.length, 1);
  assert.equal(selection.scope.matchedCount, 3);
  assert.deepEqual(selection.scope.gaps.map(x => x.reason), ['not_regular_file', 'metadata_unavailable']);
  assert.throws(() => select([file(), ...Array.from({length: 20}, (_, i) => ({name: i + '.md', type: 'missing'}))]),
    {notesReason: 'input_file_count_limit'});
});
for (const [entries, reason] of [[[], 'no_matching_inputs'],
  [[{...file(), type: 'symlink'}], 'matching_inputs_unavailable'],
  [[file('large.md', 65537)], 'input_file_size_limit'],
  [Array.from({length: 5}, (_, i) => file(i + '.md', 65536)), 'input_total_size_limit']]) {
  test('SOURCE_UNIT incomplete or over-limit scope: ' + reason, () => {
    assert.throws(() => select(entries), {notesReason: reason});
  });
}
test('SOURCE_UNIT byte limits accept four complete 64KiB inputs without truncation', () => {
  const entries = Array.from({length: 4}, (_, i) => file(i + '.md', 65536));
  assert.deepEqual(select(entries).entries, entries);
});
test('SOURCE_UNIT final request carries actual numbered material and excludes unrelated fields', () => {
  const value = JSON.parse(notesModelInput({...inputs, secret: 'not a request field'}));
  assert.deepEqual(Object.keys(value), ['task', 'sources']);
  assert.deepEqual(value.sources[0].lines[1], {line: 2, text: '待办：周五配镜，负责人小林。'});
  assert.equal(JSON.stringify(value).includes('not a request field'), false);
});
test('SOURCE_UNIT proposal requires real source lines, literal task and explicit assignee/date', () => {
  assert.deepEqual(parse({todos: [todo]}), {todos: [todo]});
  for (const change of [{source: 'unread.md'}, {startLine: 3, endLine: 3}, {quote: '无来源的新指示'},
    {task: '已预约并购买眼镜'}, {assignee: '另一个人'}, {due: '2026-12-31'}, {tool: 'shell'}]) {
    assert.throws(() => parse({todos: [{...todo, ...change}]}), error =>
      ['invalid_model_proposal', 'unverified_model_source'].includes(error.notesReason));
  }
  assert.throws(() => parse({todos: [todo, todo]}), {notesReason: 'duplicate_model_item'});
  assert.throws(() => parse({todos: [], command: 'write elsewhere'}), {notesReason: 'invalid_model_proposal'});
});
test('SOURCE_UNIT counts and empty valid page derive from actual inputs, not model assertions', () => {
  const empty = renderNotesPage(parse({todos: []}), inputs);
  assert.equal(empty.sourceCount, 1); assert.equal(empty.itemCount, 0); assert.equal(empty.state, 'done');
  assert.match(empty.content, /这些已读笔记中未见明确待办/);
  assert.match(empty.content, /完整读回 1 份，列出 0 项/);
  const withGap = {...inputs, scope: {...inputs.scope, gaps: [{name: '另一份.md', reason: 'input_changed'}]}};
  const partial = renderNotesPage(parse({todos: [todo]}), withGap);
  assert.equal(partial.state, 'partial'); assert.equal(partial.sourceCount, 1);
  assert.match(partial.content, /另一份\.md：所选版本已改变/);
});
test('SOURCE_UNIT Markdown escape keeps literal evidence and filenames from becoming active links', () => {
  const special = {...inputs, entries: [{name: '[link](evil).md', text: 'TODO: [click](evil) <script>x</script>'}]};
  const item = {source: special.entries[0].name, startLine: 1, endLine: 1, quote: special.entries[0].text,
    task: '[click](evil)', assignee: null, due: null};
  const result = renderNotesPage(readNotesProposal(JSON.stringify({todos: [item]}), special), special);
  assert.match(result.content, /\\\[click\\\]/);
  assert.match(result.content, /\\<script\\>/);
});
test('SOURCE_UNIT heuristic covers complete request and preserves unknown context window', () => {
  const body = JSON.stringify({system: notesSystem, messages: [{role: 'user', content: [{type: 'text', text: notesModelInput(inputs)}]}]});
  const estimate = notesInputEstimate(body);
  assert.equal(estimate.accepted, true); assert.equal(estimate.contextWindow, null);
  assert.equal(estimate.semantics, 'heuristic-not-tokenizer-or-usage');
  assert.equal(notesInputEstimate(body, estimate.estimatedTokens + NOTES_LIMITS.outputTokens).accepted, true);
  assert.equal(notesInputEstimate(body, estimate.estimatedTokens + NOTES_LIMITS.outputTokens - 1).accepted, false);
  assert.equal(notesInputEstimate('x'.repeat(120000), 1000000).accepted, false);
});
