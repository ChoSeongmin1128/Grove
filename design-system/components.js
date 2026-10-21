(function (root) {
  const escape = (value) => String(value ?? "").replace(/[&<>"']/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[character]);
  const attributes = (values = {}) => Object.entries(values).map(([name, value]) => {
    if (!/^(?:id|title|role|name|value|tabindex|type|class|aria-[\w-]+|data-[\w-]+)$/.test(name)) throw new Error("Unsupported component attribute: " + name);
    return value == null ? "" : ` ${name}="${escape(value)}"`;
  }).join("");
  const icon = (name) => root.GroveIcons?.(name) || "";
  const phaseName = (phase) => ["ready", "recording", "paused", "finished"].includes(phase) ? phase : "ready";
  function button({ text, html, action, className = "", withIcon = false, disabled = false, attrs = {} } = {}) {
    const content = html == null ? escape(text) : html;
    const classes = [className, withIcon ? "with-icon" : ""].filter(Boolean).join(" ");
    return `<button${attributes({ type: "button", "data-action": action, class: classes, ...attrs })}${disabled ? " disabled" : ""}>${content || ""}</button>`;
  }
  function badge(text, warning = false) { return `<span class="badge${warning ? " warn" : ""}">${escape(text)}</span>`; }
  function status(phase, label) { return `<span class="status-chip ${phaseName(phase)}">${escape(label)}</span>`; }
  function meetingRow({ title, phase, count = 0, date, label, attendeeLabel, action, attrs = {} }) {
    const state = phaseName(phase);
    return button({ action, className: "library-row", attrs,
      html: `<span class="meeting-symbol ${state}">${icon(state === "ready" ? "calendar" : state === "finished" ? "file-text" : "mic")}</span><span class="library-row-main"><strong title="${escape(title)}">${escape(title)}</strong></span><span class="library-row-people" title="${escape(attendeeLabel || (count ? count + "명" : "참석자 미지정"))}">${count ? escape(count) + "명" : "미지정"}</span><span class="library-row-date">${escape(date)}</span>${status(state, label)}${icon("chevron-right")}` });
  }
  function personRow({ name, role = "역할 미지정", initial, statusText = "목소리 미등록" }) {
    return `<div class="person-row"><span class="avatar" aria-hidden="true">${escape(initial || name?.slice(0, 1))}</span><div class="grow person-identity"><strong>${escape(name)}</strong><span class="muted">${escape(role)}</span></div><span class="person-voice-status">${escape(statusText)}</span></div>`;
  }
  function personOption({ name, role = "역할 미지정", initial, checked = false, attrs = {} }) {
    return `<label class="selector-person${checked ? " is-selected" : ""}"><input type="checkbox"${attributes(attrs)}${checked ? " checked" : ""}><span class="avatar" aria-hidden="true">${escape(initial || name?.slice(0, 1))}</span><span class="person-identity"><strong>${escape(name)}</strong><span class="muted">${escape(role)}</span></span></label>`;
  }
  function utterance({ speaker, time, tone = 0, unknown = false, current = false, editing = false, text, contentHTML, timeAction, timeAttrs = {}, actionsHTML = "", corrected = false }) {
    return `<article class="utterance${current ? " current" : ""}${editing ? " editing" : ""}"><div class="speaker-rail"><span class="speaker-avatar ${unknown ? "unknown" : "tone-" + (Math.max(0, tone) % 3)}" aria-hidden="true">${unknown ? "?" : escape(speaker?.slice(0, 1))}</span><strong>${escape(speaker)}</strong>${button({ text: time, action: timeAction, attrs: { "aria-label": time + " 발언", ...timeAttrs } })}${unknown ? badge("이름 미확인", true) : ""}</div><div>${editing ? contentHTML : `<p${current ? ' class="pending"' : ""}>${escape(text)}</p>${corrected ? '<span class="tiny muted">수정됨</span>' : ""}<div class="turn-actions">${actionsHTML}</div>`}</div></article>`;
  }
  function transcriptRow({ index, time, start, text, originalText, editing = false, disabled = false }) {
    const label = `${Number(index) + 1}번 발언`;
    const original = originalText != null && String(text ?? "") !== String(originalText)
      ? `<details class="transcript-original"><summary>원문 보기</summary><p>${escape(originalText)}</p></details>` : "";
    const content = editing
      ? `<textarea class="text-input"${attributes({ "data-segment": index, "aria-label": label + " 수정" })} rows="1" spellcheck="false"${disabled ? " readonly" : ""}>${escape(text)}</textarea><div class="transcript-edit-actions">${button({ text: "취소", className: "quiet small", disabled, attrs: { "data-transcript-cancel": index, "aria-label": label + " 수정 취소" } })}${button({ text: "완료", className: "small", disabled, attrs: { "data-transcript-done": index, "aria-label": label + " 수정 완료" } })}</div>`
      : `<p class="transcript-text">${escape(text)}</p>${original}`;
    return `<article${attributes({ class: "transcript-row" + (editing ? " is-editing" : ""), "data-transcript-row": index, tabindex: -1 })}>${button({ text: time, className: "transcript-time quiet small", attrs: { "data-seek": start, "aria-label": time + " 발언 재생" } })}<div class="transcript-content">${content}</div>${editing ? "" : `<div class="transcript-row-actions">${button({ text: "수정", className: "quiet small", disabled, attrs: { "data-transcript-edit": index, "aria-label": label + " 수정" } })}</div>`}</article>`;
  }
  function minutes(sections) {
    return `<article class="minutes-document">${sections.map(({ title, text, emptyText = "작성된 내용이 없습니다." }) => `<section><h3>${escape(title)}</h3><div class="minutes-text">${String(text || "").trim() ? escape(text) : `<span class="muted">${escape(emptyText)}</span>`}</div></section>`).join("")}</article>`;
  }
  function dialogContent({ title, titleId = "modal-title", bodyHTML = "", actionsHTML = "" }) {
    return `<h2${attributes({ id: titleId })}>${escape(title)}</h2>${bodyHTML}${actionsHTML ? `<div class="modal-footer"><span></span><div class="row">${actionsHTML}</div></div>` : ""}`;
  }
  const api = { escape, button, badge, status, meetingRow, personRow, personOption, utterance, transcriptRow, minutes, dialogContent };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.GroveUI = api;
})(typeof globalThis === "object" ? globalThis : this);
