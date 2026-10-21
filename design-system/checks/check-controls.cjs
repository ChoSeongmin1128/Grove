const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

const source = fs.readFileSync(path.join(__dirname, '../controls.js'), 'utf8');
class FixedDate extends Date {
  constructor(...values) { super(...(values.length ? values : [2026, 9, 21, 12])); }
}
class ControlEvent {
  constructor(type, values = {}) { this.type = type; Object.assign(this, values); }
  preventDefault() { this.defaultPrevented = true; }
  stopImmediatePropagation() { this.stopped = true; }
}

function calendar({ value = '2026-10-01', type = 'date', min = '', max = '', disabled = false, readOnly = false } = {}) {
  let document;
  class Element {
    constructor(tag, attributes = {}) {
      this.tagName = tag.toUpperCase(); this.attributes = {}; this.children = []; this.listeners = new Map();
      this.dataset = {}; this.parentElement = null; this.labels = []; this._html = '';
      this.disabled = false; this.hidden = false; this.readOnly = false; this.tabIndex = /^(button|input)$/.test(tag) ? 0 : -1;
      for (const [name, value] of Object.entries(attributes)) this.setAttribute(name, value);
    }
    setAttribute(name, value) {
      this.attributes[name] = String(value);
      if (name.startsWith('data-')) this.dataset[name.slice(5).replace(/-([a-z])/g, (_, letter) => letter.toUpperCase())] = String(value);
      else if (name === 'tabindex') this.tabIndex = Number(value);
      else if (name === 'disabled' || name === 'hidden') this[name] = true;
      else if (['id', 'type', 'value'].includes(name)) this[name] = String(value);
    }
    getAttribute(name) { return this.attributes[name] ?? null; }
    get className() { return this.attributes.class || ''; }
    set className(value) { this.attributes.class = value; }
    get isConnected() { return this === document.body || Boolean(this.parentElement?.isConnected); }
    before(node) { const siblings = this.parentElement.children; node.parentElement = this.parentElement; siblings.splice(siblings.indexOf(this), 0, node); }
    append(...nodes) { for (const node of nodes) { node.remove(); node.parentElement = this; this.children.push(node); } }
    remove() { if (this.parentElement) this.parentElement.children.splice(this.parentElement.children.indexOf(this), 1); this.parentElement = null; }
    contains(node) { return node === this || this.children.some(child => child.contains(node)); }
    matches(selector) {
      if (selector === ':popover-open') return Boolean(this.open);
      const direct = selector.replace(/:not\(:disabled\)/g, '');
      if (direct !== selector && this.disabled) return false;
      const tag = direct.match(/^[a-z-]+/i)?.[0];
      if (tag && tag.toUpperCase() !== this.tagName) return false;
      for (const [, name] of direct.matchAll(/\.([\w-]+)/g)) if (!this.className.split(/\s+/).includes(name)) return false;
      for (const [, name] of direct.matchAll(/#([\w-]+)/g)) if (this.id !== name) return false;
      for (const [, name, value] of direct.matchAll(/\[([\w-]+)(?:="([^"]*)")?\]/g)) {
        const current = name === 'tabindex' ? String(this.tabIndex) : this.getAttribute(name);
        if (current == null || (value != null && current !== value)) return false;
      }
      return true;
    }
    closest(selector) { return selector.split(',').some(part => this.matches(part.trim())) ? this : this.parentElement?.closest(selector) || null; }
    querySelectorAll(selector) {
      const all = this.children.flatMap(child => [child, ...child.querySelectorAll('*')]);
      return all.filter(node => selector.split(',').some(part => node.matches(part.trim())));
    }
    querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
    addEventListener(name, listener) { const listeners = this.listeners.get(name) || []; listeners.push(listener); this.listeners.set(name, listeners); }
    dispatchEvent(event) { event.target ||= this; for (const listener of this.listeners.get(event.type) || []) { listener(event); if (event.stopped) break; } return !event.defaultPrevented; }
    focus() { if (!this.disabled && this.isConnected) { document.activeElement = this; document.dispatchEvent(new ControlEvent('focusin', { target: this })); } }
    showPopover() { this.open = true; }
    hidePopover() { this.open = false; }
    getBoundingClientRect() { return { left: 20, right: 180, top: 20, bottom: 55, width: 160, height: 320 }; }
    get style() { return this._style ||= {}; }
    get innerHTML() { return this._html; }
    set innerHTML(value) {
      this._html = value;
      for (const child of this.children) child.parentElement = null;
      this.children = [];
      const stack = [this];
      for (const [, closing, tag, raw] of value.matchAll(/<(\/)?([a-z][\w-]*)([^>]*)>/gi)) {
        if (closing) { if (stack.length > 1) stack.pop(); continue; }
        const attributes = Object.fromEntries([...raw.matchAll(/([\w-]+)(?:="([^"]*)")?/g)].map(([, name, value]) => [name, value || '']));
        const node = new Element(tag, attributes); stack.at(-1).append(node);
        if (!['input', 'br', 'hr', 'img', 'path'].includes(tag) && !raw.endsWith('/')) stack.push(node);
      }
    }
  }
  const body = new Element('body');
  document = new Element('document');
  document.body = body; document.activeElement = body; document.readyState = 'complete';
  document.createElement = tag => new Element(tag);
  document.querySelectorAll = selector => body.querySelectorAll(selector);
  const input = new Element('input', { type, 'aria-label': '회의 날짜' });
  Object.assign(input, { value, min, max, disabled, readOnly }); body.append(input);
  const window = { document, addEventListener() {}, GroveIcons: () => '' };
  vm.runInNewContext(source, { window, document, innerWidth: 1000, innerHeight: 800, Date: FixedDate, Event: ControlEvent, MutationObserver: class { observe() {} }, queueMicrotask });
  const trigger = body.querySelector('.grove-date-trigger');
  const popup = body.querySelector('.grove-calendar');
  const click = node => { if (!node.disabled) { node.focus(); (node === trigger ? trigger : popup).dispatchEvent(new ControlEvent('click', { target: node })); } };
  const key = (node, name, values = {}) => { const event = new ControlEvent('keydown', { target: node, key: name, ...values }); (name === 'Escape' ? document : popup).dispatchEvent(event); return event; };
  return { input, trigger, popup, document, controls: window.GroveControls, click, key,
    entry: () => popup.querySelectorAll('[data-date][tabindex="0"]:not(:disabled)'),
    month: offset => popup.querySelector(`[data-month="${offset}"]`),
    day: value => popup.querySelector(`[data-date="${value}"]`),
  };
}

test('month buttons preserve a keyboard date entry without selecting a different value', () => {
  const app = calendar(); app.click(app.trigger);
  assert.equal(app.document.activeElement.dataset.date, '2026-10-01');
  app.click(app.month(1));
  assert.equal(app.document.activeElement.dataset.month, '1');
  assert.deepEqual(app.entry().map(node => node.dataset.date), ['2026-11-01']);
  assert.equal(app.input.value, '2026-10-01');
  assert.equal(app.popup.querySelector('[data-date][aria-selected="true"]'), null);
  app.entry()[0].focus(); app.key(app.entry()[0], 'ArrowRight');
  assert.equal(app.document.activeElement.dataset.date, '2026-11-02');
  app.click(app.document.activeElement);
  assert.equal(app.input.value, '2026-11-02');
  assert.equal(app.controls.isOpen(), false);
  assert.equal(app.document.activeElement, app.trigger);
});

test('month navigation clamps the keyboard day to the end of a shorter month', () => {
  const app = calendar({ value: '2027-01-31' }); app.click(app.trigger); app.click(app.month(1));
  assert.deepEqual(app.entry().map(node => node.dataset.date), ['2027-02-28']);
  app.click(app.month(-1));
  assert.deepEqual(app.entry().map(node => node.dataset.date), ['2027-01-28']);
  assert.equal(app.input.value, '2027-01-31');
});

test('date entry respects min/max and never enables an unavailable month', () => {
  const app = calendar({ value: '2026-10-10', min: '2026-10-10', max: '2026-11-05' });
  app.click(app.trigger); app.key(app.document.activeElement, 'ArrowLeft');
  assert.equal(app.document.activeElement.dataset.date, '2026-10-10');
  assert.equal(app.day('2026-10-09').disabled, true);
  app.click(app.month(1));
  assert.deepEqual(app.entry().map(node => node.dataset.date), ['2026-11-01']);
  assert.equal(app.day('2026-11-06').disabled, true);
  app.click(app.day('2026-11-06'));
  assert.equal(app.input.value, '2026-10-10');
  app.click(app.month(1));
  assert.equal(app.entry().length, 0);
  assert.ok(app.popup.querySelectorAll('[data-date]').every(node => node.disabled));
  app.click(app.month(-1));
  assert.equal(app.entry().length, 1);
});

test('opening an empty date beyond today chooses one enabled date within its range', () => {
  const app = calendar({ value: '', min: '2026-11-10', max: '2026-11-15' });
  app.click(app.trigger);
  assert.deepEqual(app.entry().map(node => node.dataset.date), ['2026-11-10']);
  assert.equal(app.document.activeElement, app.entry()[0]);
  assert.equal(app.input.value, '');
});

test('keyboard month changes and Escape leave the committed date intact', () => {
  const app = calendar({ value: '2027-01-31' }); app.click(app.trigger);
  app.key(app.document.activeElement, 'PageDown');
  assert.equal(app.document.activeElement.dataset.date, '2027-02-28');
  assert.equal(app.entry().length, 1);
  const event = app.key(app.document.activeElement, 'Escape');
  assert.equal(event.defaultPrevented, true);
  assert.equal(app.controls.isOpen(), false);
  assert.equal(app.document.activeElement, app.trigger);
  assert.equal(app.input.value, '2027-01-31');
});

test('datetime month browsing does not change the pending selection or time before apply', () => {
  const app = calendar({ type: 'datetime-local', value: '2026-10-01T14:30', min: '2026-10-01T10:00', max: '2026-11-05T18:00' });
  app.click(app.trigger); app.click(app.month(1));
  assert.deepEqual(app.entry().map(node => node.dataset.date), ['2026-11-01']);
  assert.equal(app.input.value, '2026-10-01T14:30');
  app.click(app.day('2026-11-03'));
  assert.equal(app.input.value, '2026-10-01T14:30');
  assert.equal(app.day('2026-11-03').getAttribute('aria-selected'), 'true');
  app.click(app.popup.querySelector('[data-calendar="apply"]'));
  assert.equal(app.input.value, '2026-11-03T14:30');
  assert.equal(app.document.activeElement, app.trigger);
});

test('disabled and read-only date fields do not open a calendar', () => {
  for (const options of [{ disabled: true }, { readOnly: true }]) {
    const app = calendar(options); app.click(app.trigger);
    assert.equal(app.trigger.disabled, true);
    assert.equal(app.controls.isOpen(), false);
  }
});
