(function (root) {
  const records = new Set(), controls = new WeakMap();
  let active = null, sequence = 0;
  const esc = (value) => String(value ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
  const icon = (name) => root.GroveIcons?.(name) || (name === "chevron-down" ? '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="m6 9 6 6 6-6"/></svg>' : "");
  const dateAt = (year, month, day) => { const d = new Date(0); d.setHours(12, 0, 0, 0); d.setFullYear(year, month, day); return d; };
  const dateKey = (date) => String(date.getFullYear()).padStart(4, "0") + "-" + String(date.getMonth() + 1).padStart(2, "0") + "-" + String(date.getDate()).padStart(2, "0");
  function parseDate(value) {
    const match = /^(\d{4})-(\d{2})-(\d{2})(?:T|$)/.exec(value || "");
    if (!match) return null;
    const date = dateAt(+match[1], +match[2] - 1, +match[3]);
    return dateKey(date) === match[0].replace(/T$/, "") ? date : null;
  }
  function labelFor(input) {
    const label = [...(input.labels || [])].map((node) => { const copy = node.cloneNode(true); copy.querySelectorAll("input,select,textarea,button").forEach((child) => child.remove()); return copy.textContent.trim(); }).filter(Boolean).join(" ");
    return input.getAttribute("aria-label") || label || input.getAttribute("placeholder") || (input.tagName === "SELECT" ? "선택" : "날짜 선택");
  }
  function close(restore = false) {
    const previous = active;
    if (!previous) return;
    active = null;
    if (previous.popup.matches(":popover-open")) previous.popup.hidePopover();
    previous.trigger.setAttribute("aria-expanded", "false");
    if (restore && previous.trigger.isConnected) previous.trigger.focus({ preventScroll: true });
  }
  function place(record) {
    const rect = record.trigger.getBoundingClientRect(), popup = record.popup;
    const width = Math.min(innerWidth - 16, record.kind === "date" ? 302 : Math.max(rect.width, 160));
    popup.style.width = width + "px";
    popup.style.maxHeight = Math.max(120, record.kind === "date" ? innerHeight - 16 : Math.min(350, innerHeight - 16)) + "px";
    const height = popup.getBoundingClientRect().height;
    popup.style.left = Math.max(8, Math.min(rect.left, innerWidth - width - 8)) + "px";
    popup.style.top = Math.max(8, rect.bottom + 6 + height <= innerHeight - 8 ? rect.bottom + 6 : rect.top - height - 6) + "px";
  }
  function show(record) {
    if (record.input.disabled || record.input.readOnly) return;
    if (active === record) { close(true); return; }
    close();
    active = record;
    const layer = record.trigger.closest("dialog[open],#desktop-root") || document.body;
    layer.append(record.popup); record.popup.inert = false;
    record.trigger.setAttribute("aria-expanded", "true");
    record.popup.showPopover();
    place(record);
    record.open();
  }
  function commit(record, value) {
    const changed = record.input.value !== value;
    record.input.value = value;
    record.refresh();
    close(true);
    if (changed) {
      record.input.dispatchEvent(new Event("input", { bubbles: true }));
      record.input.dispatchEvent(new Event("change", { bubbles: true }));
    }
  }
  function base(input, kind) {
    const hadFocus = document.activeElement === input;
    const label = labelFor(input);
    const wrapper = document.createElement("span"), trigger = document.createElement("button"), popup = document.createElement("div");
    wrapper.className = kind === "select" ? "grove-select" : "grove-date";
    trigger.type = "button"; trigger.className = wrapper.className + "-trigger";
    trigger.setAttribute("aria-haspopup", kind === "select" ? "listbox" : "dialog");
    trigger.setAttribute("aria-expanded", "false");
    if (input.dataset.field) trigger.dataset.field = input.dataset.field;
    popup.id = "grove-control-popup-" + (++sequence); popup.popover = "manual";
    popup.className = kind === "select" ? "grove-select-popover" : "grove-calendar";
    popup.setAttribute("role", kind === "select" ? "listbox" : "dialog");
    popup.setAttribute("aria-label", label);
    trigger.setAttribute("aria-controls", popup.id);
    input.before(wrapper); wrapper.append(trigger, input); document.body.append(popup);
    input.hidden = true; input.tabIndex = -1;
    const record = { input, wrapper, trigger, popup, kind, label };
    controls.set(input, record); records.add(record);
    trigger.addEventListener("click", () => show(record));
    trigger.addEventListener("keydown", (event) => {
      if (event.isComposing || event.keyCode === 229 || !["ArrowDown", "ArrowUp"].includes(event.key)) return;
      event.preventDefault(); if (active !== record) show(record);
    });
    input.addEventListener("change", () => record.refresh());
    input.addEventListener("invalid", (event) => { event.preventDefault(); trigger.setAttribute("aria-invalid", "true"); trigger.focus({ preventScroll: true }); });
    if (hadFocus) queueMicrotask(() => trigger.focus({ preventScroll: true }));
    return record;
  }
  function enhanceSelect(input) {
    if (input.multiple || input.size > 1 || controls.has(input)) return;
    const record = base(input, "select");
    let current = -1;
    const enabled = (index) => { const option = input.options[index]; return option && !option.disabled && !option.parentElement.disabled; };
    function highlight(index) {
      current = index;
      [...record.popup.querySelectorAll("[role=option]")].forEach((node, i) => node.classList.toggle("is-active", i === index));
      const node = record.popup.querySelector(`[data-option="${index}"]`);
      if (node) { record.popup.setAttribute("aria-activedescendant", node.id); node.scrollIntoView({ block: "nearest" }); }
    }
    record.refresh = () => {
      const selected = input.options[input.selectedIndex];
      record.trigger.disabled = input.disabled;
      record.trigger.setAttribute("aria-label", record.label + ": " + (selected?.textContent || "선택"));
      record.trigger.innerHTML = `<span class="grove-select-value">${esc(selected?.textContent || "선택")}</span><span class="grove-select-chevron">${icon("chevron-down")}</span>`;
      record.popup.innerHTML = [...input.options].map((option, index) => `<div id="${record.popup.id}-${index}" class="grove-select-option${index === input.selectedIndex ? " is-selected" : ""}" role="option" aria-selected="${index === input.selectedIndex}" aria-disabled="${!enabled(index)}" data-option="${index}"><span>${esc(option.textContent)}</span></div>`).join("");
      if (active === record) { highlight(enabled(current) ? current : [...input.options].findIndex((_, i) => enabled(i))); place(record); }
    };
    record.open = () => { record.popup.tabIndex = -1; record.popup.focus({ preventScroll: true }); highlight(enabled(input.selectedIndex) ? input.selectedIndex : [...input.options].findIndex((_, i) => enabled(i))); };
    record.popup.addEventListener("click", (event) => { const node = event.target.closest("[data-option]"); if (node && enabled(+node.dataset.option)) commit(record, input.options[+node.dataset.option].value); });
    record.popup.addEventListener("pointermove", (event) => { const node = event.target.closest("[data-option]"); if (node && enabled(+node.dataset.option)) highlight(+node.dataset.option); });
    record.popup.addEventListener("keydown", (event) => {
      if (event.isComposing || event.keyCode === 229) return;
      const choices = [...input.options].map((_, index) => index).filter(enabled);
      if (["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key)) {
        event.preventDefault();
        const index = choices.indexOf(current);
        highlight(event.key === "Home" ? choices[0] : event.key === "End" ? choices.at(-1) : choices[(index + (event.key === "ArrowDown" ? 1 : -1) + choices.length) % choices.length]);
      } else if (["Enter", " "].includes(event.key) && enabled(current)) { event.preventDefault(); commit(record, input.options[current].value); }
      else if (event.key === "Tab") close(true);
    });
    record.refresh();
  }
  function enhanceDate(input) {
    if (controls.has(input)) return;
    const record = base(input, "date"), timed = input.type === "datetime-local";
    let month, pending, time, focusedDate;
    const allowed = (value) => (!input.min || value >= input.min.slice(0, 10)) && (!input.max || value <= input.max.slice(0, 10));
    const save = (value) => {
      if (timed && value) {
        if (!/^([01]\d|2[0-3]):[0-5]\d$/.test(time)) { record.popup.querySelector(".grove-calendar-error").hidden = false; return; }
        value += "T" + time;
      }
      if (value && ((input.min && value < input.min) || (input.max && value > input.max))) { record.popup.querySelector(".grove-calendar-error").hidden = false; return; }
      commit(record, value);
    };
    function render(focusKey) {
      const today = dateKey(new Date()), first = dateAt(month.getFullYear(), month.getMonth(), 1), start = dateAt(first.getFullYear(), first.getMonth(), 1 - first.getDay());
      const dates = Array.from({ length: 42 }, (_, index) => dateAt(start.getFullYear(), start.getMonth(), start.getDate() + index));
      const available = dates.filter(date => allowed(dateKey(date))), preferred = focusKey || focusedDate || pending || today;
      const entry = available.find(date => dateKey(date) === preferred) || available.find(date => date.getMonth() === month.getMonth()) || available[0];
      focusedDate = entry ? dateKey(entry) : null;
      const days = dates.map(date => { const key = dateKey(date); return `<button type="button" role="gridcell" data-date="${key}" tabindex="${key === focusedDate && allowed(key) ? 0 : -1}" aria-label="${key}" aria-selected="${key === pending}"${allowed(key) ? "" : " disabled"} class="${date.getMonth() !== month.getMonth() ? "is-outside " : ""}${key === today ? "is-today " : ""}${key === pending ? "is-selected" : ""}">${date.getDate()}</button>`; });
      record.popup.innerHTML = `<div class="grove-calendar-heading"><button type="button" data-month="-1" aria-label="이전 달">${icon("chevron-left")}</button><strong class="grove-calendar-month" aria-live="polite">${month.getFullYear()}년 ${month.getMonth() + 1}월</strong><button type="button" data-month="1" aria-label="다음 달">${icon("chevron-right")}</button></div><div class="grove-calendar-weekdays" aria-hidden="true">${["일", "월", "화", "수", "목", "금", "토"].map((day) => `<span>${day}</span>`).join("")}</div><div class="grove-calendar-grid" role="grid" aria-label="날짜">${Array.from({ length: 6 }, (_, week) => `<div class="grove-calendar-week" role="row" style="display:contents">${days.slice(week * 7, week * 7 + 7).join("")}</div>`).join("")}</div>${timed ? `<label class="grove-calendar-time">시간<input type="text" inputmode="numeric" aria-label="시간" placeholder="09:00" value="${esc(time)}" maxlength="5"></label>` : ""}<p class="grove-calendar-error" role="alert" hidden>선택 가능한 날짜와 시간을 확인해 주세요.</p><div class="grove-calendar-footer"><button type="button" class="grove-calendar-clear quiet" data-calendar="clear">지우기</button><button type="button" class="grove-calendar-today quiet" data-calendar="today"${allowed(today) ? "" : " disabled"}>오늘</button>${timed ? '<button type="button" class="primary" data-calendar="apply">적용</button>' : ""}</div>`;
      place(record);
      if (focusKey) record.popup.querySelector(`[data-date="${focusedDate}"]:not(:disabled)`)?.focus({ preventScroll: true });
    }
    record.refresh = () => {
      const date = parseDate(input.value), value = date ? `${date.getFullYear()}.${String(date.getMonth() + 1).padStart(2, "0")}.${String(date.getDate()).padStart(2, "0")}${timed ? " " + input.value.slice(11, 16) : ""}` : "날짜 선택";
      record.trigger.disabled = input.disabled || input.readOnly;
      record.trigger.setAttribute("aria-label", record.label + ": " + value);
      record.trigger.innerHTML = `<span>${esc(value)}</span>${icon("calendar-days")}`;
    };
    record.open = () => {
      pending = input.value.slice(0, 10); time = input.value.slice(11, 16) || "09:00";
      focusedDate = pending || dateKey(new Date());
      month = parseDate(input.value) || new Date();
      if (input.min && dateKey(month) < input.min.slice(0, 10)) month = parseDate(input.min) || month;
      if (input.max && dateKey(month) > input.max.slice(0, 10)) month = parseDate(input.max) || month;
      month = dateAt(month.getFullYear(), month.getMonth(), 1);
      render();
      const chosen = record.popup.querySelector('[data-date][tabindex="0"]:not(:disabled)') || record.popup.querySelector('[data-date]:not(:disabled)');
      if (chosen) { chosen.tabIndex = 0; chosen.focus({ preventScroll: true }); }
      else record.popup.querySelector("button:not(:disabled)")?.focus({ preventScroll: true });
    };
    record.popup.addEventListener("input", (event) => { if (event.target.matches(".grove-calendar-time input")) { time = event.target.value; record.popup.querySelector(".grove-calendar-error").hidden = true; } });
    record.popup.addEventListener("click", (event) => {
      const button = event.target.closest("button"); if (!button || button.disabled) return;
      if (button.dataset.date) { pending = button.dataset.date; if (timed) render(pending); else save(pending); }
      else if (button.dataset.month) {
        const day = parseDate(focusedDate)?.getDate() || 1;
        month = dateAt(month.getFullYear(), month.getMonth() + +button.dataset.month, 1);
        focusedDate = dateKey(dateAt(month.getFullYear(), month.getMonth(), Math.min(day, dateAt(month.getFullYear(), month.getMonth() + 1, 0).getDate())));
        render(); record.popup.querySelector(`[data-month="${button.dataset.month}"]`)?.focus({ preventScroll: true });
      }
      else if (button.dataset.calendar === "clear") save("");
      else if (button.dataset.calendar === "today") { pending = dateKey(new Date()); if (timed) { month = new Date(); render(pending); } else save(pending); }
      else if (button.dataset.calendar === "apply") { if (pending) save(pending); }
    });
    record.popup.addEventListener("keydown", (event) => {
      if (event.key === "Tab") {
        const nodes = [...record.popup.querySelectorAll('button:not(:disabled),input:not(:disabled)')].filter((node) => node.tabIndex >= 0);
        if (event.shiftKey && document.activeElement === nodes[0]) { event.preventDefault(); nodes.at(-1)?.focus(); }
        else if (!event.shiftKey && document.activeElement === nodes.at(-1)) { event.preventDefault(); nodes[0]?.focus(); }
        return;
      }
      const button = event.target.closest("[data-date]");
      if (!button || !["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Home", "End", "PageUp", "PageDown"].includes(event.key)) return;
      event.preventDefault();
      const date = parseDate(button.dataset.date);
      let next = dateAt(date.getFullYear(), date.getMonth(), date.getDate() + ({ ArrowLeft: -1, ArrowRight: 1, ArrowUp: -7, ArrowDown: 7, Home: -date.getDay(), End: 6 - date.getDay() }[event.key] || 0));
      if (["PageUp", "PageDown"].includes(event.key)) { const offset = event.key === "PageDown" ? 1 : -1, last = dateAt(date.getFullYear(), date.getMonth() + offset + 1, 0).getDate(); next = dateAt(date.getFullYear(), date.getMonth() + offset, Math.min(date.getDate(), last)); }
      if (!allowed(dateKey(next))) return;
      month = dateAt(next.getFullYear(), next.getMonth(), 1); render(dateKey(next));
    });
    record.refresh();
  }
  function enhanceAll(container = document) {
    container.querySelectorAll("select").forEach(enhanceSelect);
    container.querySelectorAll('input[type="date"],input[type="datetime-local"]').forEach(enhanceDate);
    for (const record of records) if (!record.input.isConnected) { if (active === record) close(); record.popup.remove(); records.delete(record); }
  }
  function refresh() { for (const record of records) if (record.input.isConnected) record.refresh(); }
  document.addEventListener("pointerdown", (event) => { if (active && !active.popup.contains(event.target) && !active.wrapper.contains(event.target)) close(); }, true);
  document.addEventListener("keydown", (event) => { if (active && event.key === "Escape" && !event.isComposing) { event.preventDefault(); event.stopImmediatePropagation(); close(true); } }, true);
  document.addEventListener("focusin", (event) => { if (active && !active.popup.contains(event.target) && !active.wrapper.contains(event.target)) close(); });
  window.addEventListener("resize", () => { if (active) place(active); });
  document.addEventListener("scroll", (event) => { if (active && !active.popup.contains(event.target)) close(); }, true);
  let queued = false;
  function initialize() {
    enhanceAll();
    new MutationObserver(() => { if (queued) return; queued = true; queueMicrotask(() => { queued = false; enhanceAll(); }); }).observe(document.body, { childList: true, subtree: true });
  }
  root.GroveControls = { enhanceAll, refresh, close: () => close(true), isOpen: () => !!active };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", initialize, { once: true }); else initialize();
})(window);
