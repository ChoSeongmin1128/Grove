export function createMeetingSearch({ search, apply, delay = 250, schedule = setTimeout, clear = clearTimeout }) {
  let generation = 0, timer;
  return {
    update(query, includeDeleted = false) {
      const request = ++generation;
      clear(timer);
      if (!query.trim()) { apply({ query: '', ids: null, unavailable: 0, pending: false }); return; }
      apply({ query, ids: null, unavailable: 0, pending: true });
      timer = schedule(async () => {
        try {
          const result = await search(query, includeDeleted);
          if (request === generation) apply({ query, ids: result.ids, unavailable: result.unavailable, pending: false });
        } catch {
          if (request === generation) apply({ query, ids: null, unavailable: 1, pending: false });
        }
      }, delay);
    },
    reset() { generation++; clear(timer); },
  };
}
