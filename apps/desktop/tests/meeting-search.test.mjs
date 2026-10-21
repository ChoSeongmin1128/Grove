import assert from 'node:assert/strict';
import test from 'node:test';
import { createMeetingSearch } from '../src/meeting-search.js';

test('search never accepts an older request after changing query or view', async () => {
  const tasks=[], requests=[], results=[];
  const search=createMeetingSearch({search:(query,deleted)=>new Promise(resolve=>requests.push({query,deleted,resolve})), apply:result=>results.push(result), schedule:task=>{tasks.push(task);return tasks.length;}, clear(){} });
  search.update('회의',false); const first=tasks.pop()();
  search.update('회의',true); const second=tasks.pop()();
  assert.equal(requests[1].deleted,true);
  requests[1].resolve({ids:['trash'],unavailable:0}); await second;
  requests[0].resolve({ids:['active'],unavailable:0}); await first;
  assert.deepEqual(results.at(-1).ids,['trash']);
  search.update(''); assert.equal(results.at(-1).ids,null);
});
