/* Snapshot panel view.
 *
 * Ruby owns all state. This file only draws whatever `SnapshotUI.render(state)`
 * is handed and forwards user intent back through the `sketchup` bridge.
 *
 * Everything is built with createElement/textContent rather than innerHTML:
 * snapshot messages and option names are user text, and this way they can
 * never be interpreted as markup.
 */
(function () {
  'use strict';

  var app = document.getElementById('app');

  // Modus carries both palettes and switches on this attribute, so following
  // the OS is all that dark mode needs — there is no second stylesheet.
  function applyTheme() {
    var dark = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
    document.documentElement.setAttribute('data-bs-theme', dark ? 'dark' : 'light');
  }

  applyTheme();
  if (window.matchMedia) {
    var scheme = window.matchMedia('(prefers-color-scheme: dark)');
    if (scheme.addEventListener) { scheme.addEventListener('change', applyTheme); }
  }

  // Kept across re-renders so a half-typed message is not wiped when Ruby
  // pushes fresh state, and so a row the user opened stays open.
  var draft = { message: '' };
  var open = { settings: false };
  var renaming = null;           // sha being renamed
  var namingVariation = false;   // the inline "new variation" field is open
  var focusVariationField = false; // one-shot: focus it on the next render
  var NEW_VARIATION = '\u0000new';  // sentinel value in the variation picker
  var pendingFocus = null;       // input to focus once it is in the document
  var lastState = null;

  function bridge(name) {
    if (typeof window.sketchup === 'undefined' || !window.sketchup[name]) {
      return; // running outside SketchUp (e.g. opened in a browser to style it)
    }
    window.sketchup[name].apply(window.sketchup, Array.prototype.slice.call(arguments, 1));
  }

  function el(tag, className, text) {
    var node = document.createElement(tag);
    if (className) { node.className = className; }
    if (text !== undefined && text !== null) { node.textContent = String(text); }
    return node;
  }

  function button(label, className, onClick) {
    var b = el('button', className, label);
    b.type = 'button';
    b.addEventListener('click', onClick);
    return b;
  }

  function textInput(className, value, placeholder) {
    var input = document.createElement('input');
    input.type = 'text';
    input.className = 'form-control form-control-sm' + (className ? ' ' + className : '');
    input.value = value || '';
    if (placeholder) { input.placeholder = placeholder; }
    return input;
  }

  var CAMERA_SVG =
    '<svg viewBox="0 0 32 32" aria-hidden="true" focusable="false">' +
    '<defs><mask id="snapshot-lens">' +
    '<rect width="32" height="32" fill="white"/>' +
    '<circle cx="16" cy="17.8" r="6.8" fill="black"/>' +
    '<circle cx="16" cy="17.8" r="3.5" fill="white"/>' +
    '</mask></defs>' +
    '<g fill="currentColor" mask="url(#snapshot-lens)">' +
    '<rect x="11" y="4" width="10" height="6" rx="1.8"/>' +
    '<rect x="2" y="7.6" width="28" height="20.4" rx="4.2"/>' +
    '</g></svg>';

  // The only innerHTML in this file, and the only place it is defensible: a
  // constant this file owns, with no user text anywhere near it.
  function iconButton(svg, label, className, onClick) {
    var b = el('button', 'icon-button ' + className);
    b.type = 'button';
    b.title = label;
    b.setAttribute('aria-label', label);
    b.innerHTML = svg;
    b.addEventListener('click', onClick);
    return b;
  }

  function redraw() {
    render(lastState);
  }

  /* --- formatting -------------------------------------------------------- */

  function relativeTime(iso) {
    var then = Date.parse(iso);
    if (isNaN(then)) { return ''; }

    var seconds = Math.round((Date.now() - then) / 1000);
    if (seconds < 45) { return 'just now'; }

    var units = [
      ['minute', 60],
      ['hour', 3600],
      ['day', 86400],
      ['week', 604800],
      ['month', 2629800],
      ['year', 31557600]
    ];
    var index = 0;
    for (var i = 0; i < units.length; i++) {
      if (seconds >= units[i][1]) { index = i; }
    }

    var value = Math.round(seconds / units[index][1]);

    // Rounding can push the count up to exactly the next unit, which is how
    // "60 minutes ago", "24 hours ago" and "12 months ago" happened. Promote
    // until it no longer does.
    while (index + 1 < units.length && value * units[index][1] >= units[index + 1][1]) {
      index += 1;
      value = Math.round(seconds / units[index][1]);
    }

    return value + ' ' + units[index][0] + (value === 1 ? '' : 's') + ' ago';
  }

  function absoluteTime(iso) {
    var date = new Date(iso);
    if (isNaN(date.getTime())) { return iso || ''; }
    return date.toLocaleString();
  }

  /* --- sections ---------------------------------------------------------- */

  // The current variation and the way to change it are the same control.
  // They used to be a badge at the top and a section at the bottom, with
  // nothing connecting the two.
  function header(state) {
    var box = el('div', 'header');
    box.appendChild(el('h1', 'model-name', state.model_name || 'No model open'));

    if (!state.tracked) { return box; }

    var variations = state.variations || [];
    var bar = el('div', 'variation-bar');
    bar.appendChild(el('span', 'variation-caption', 'Working on'));

    var select = document.createElement('select');
    select.className = 'form-select form-select-sm variation-select';
    variations.forEach(function (variation) {
      var choice = document.createElement('option');
      choice.value = variation.name;
      choice.textContent = variation.label;
      choice.selected = !!variation.current;
      select.appendChild(choice);
    });

    var creator = document.createElement('option');
    creator.value = NEW_VARIATION;
    creator.textContent = 'New variation…';
    select.appendChild(creator);

    select.addEventListener('change', function () {
      if (select.value === NEW_VARIATION) {
        // Opens the inline field below; the picker resets when it is rebuilt.
        namingVariation = true;
        focusVariationField = true;
        redraw();
      } else {
        bridge('su_switch_variation', select.value);
      }
    });

    bar.appendChild(select);

    if (namingVariation) { bar.appendChild(variationNameField(state)); }
    box.appendChild(bar);

    // A paying customer should never see licensing UI, so this only appears
    // during a trial or once one has run out.
    var trial = trialBadge(state.license);
    if (trial) { box.appendChild(trial); }

    // Explain the idea only until they have used it.
    if (variations.length <= 1) {
      box.appendChild(el('p', 'hint',
        'A variation is a separate line of snapshots. Start one to try a ' +
        'different idea without disturbing this one, then switch back here.'));
    }

    return box;
  }

  function notice(text) {
    return el('p', 'notice', text);
  }

  // Naming a variation happens here rather than in a dialog, so every field in
  // the extension lives in the same window.
  function variationNameField(state) {
    var box = el('div', 'field-row');
    var input = textInput(null, state.suggested_variation || '', 'Name this variation');

    var create = function () {
      var text = input.value.trim();
      if (!text) { input.focus(); return; }
      namingVariation = false;
      bridge('su_create_variation', text);
    };

    var cancel = function () {
      namingVariation = false;
      redraw();
    };

    input.addEventListener('keydown', function (event) {
      if (event.key === 'Enter') { event.preventDefault(); create(); }
      if (event.key === 'Escape') { event.preventDefault(); cancel(); }
    });

    box.appendChild(input);
    box.appendChild(button('Create', 'btn btn-primary btn-sm', create));
    box.appendChild(button('Cancel', 'btn btn-outline-secondary btn-sm', cancel));

    if (focusVariationField) {
      focusVariationField = false;
      pendingFocus = input;
    }
    return box;
  }

  function trialBadge(license) {
    if (!license) { return null; }
    if (license.licensed && !license.trial) { return null; }

    var box = el('p', 'trial' + (license.licensed ? '' : ' ended'));
    if (license.trial) {
      var days = license.days_remaining;
      box.appendChild(document.createTextNode(
        days === null || days === undefined
          ? 'Trial'
          : 'Trial — ' + days + (days === 1 ? ' day left' : ' days left')));
    } else {
      box.appendChild(document.createTextNode(
        'Trial ended. Your snapshots are still here; new ones are paused.'));
    }
    box.appendChild(document.createTextNode(' '));
    box.appendChild(button('Buy', 'btn btn-link btn-sm', function () { bridge('su_buy'); }));
    return box;
  }

  // Deliberately not wrapped in a bordered section: it is the one thing the
  // panel is for, and a box around it only adds a line to look at.
  function composeSection(state) {
    var box = el('div', 'compose');
    var input = textInput(null, draft.message, 'What changed?');
    input.addEventListener('input', function () { draft.message = input.value; });

    var submit = function () {
      var text = input.value.trim();
      if (!text) { input.focus(); return; }
      draft.message = '';
      bridge('su_snapshot', text);
    };

    input.addEventListener('keydown', function (event) {
      if (event.key === 'Enter') { event.preventDefault(); submit(); }
    });

    var row = el('div', 'field-row');
    row.appendChild(input);
    row.appendChild(iconButton(CAMERA_SVG, 'Take a snapshot', 'btn btn-primary btn-sm', submit));
    box.appendChild(row);

    // One sentence covers both states. A pill next to the picker said the
    // same thing in fewer, vaguer words.
    if (state.dirty) {
      box.appendChild(el('p', 'hint', 'You have changes that aren\u2019t in a snapshot yet.'));
    } else if ((state.snapshots || []).length) {
      box.appendChild(el('p', 'hint', 'Nothing has changed since your last snapshot.'));
    }

    return box;
  }

  /* --- history ----------------------------------------------------------- */

  function renameField(snap) {
    var input = textInput('snap-rename', snap.subject);

    var commit = function () {
      if (renaming !== snap.sha) { return; } // already handled
      var text = input.value.trim();
      renaming = null;
      if (text && text !== snap.subject) {
        bridge('su_rename', snap.sha, text);
      } else {
        redraw();
      }
    };

    input.addEventListener('keydown', function (event) {
      if (event.key === 'Enter') {
        event.preventDefault();
        commit();
      } else if (event.key === 'Escape') {
        event.preventDefault();
        renaming = null;
        redraw();
      }
    });
    input.addEventListener('blur', commit);

    pendingFocus = input;
    return input;
  }

  function historyRow(template, snap) {
    var item = template.content.firstElementChild.cloneNode(true);
    if (snap.head) { item.classList.add('current'); }

    var body = item.querySelector('.snap-body');
    var subject = item.querySelector('.snap-subject');
    var editing = renaming === snap.sha;

    // A double-click begins with a single click, and double-click is how you
    // rename. So a row click waits briefly to see whether a second one is
    // coming, and the rename cancels it. The delay is invisible next to
    // reopening the model, which is what a restore does anyway.
    var pendingClick = null;

    var cancelPendingClick = function () {
      if (pendingClick) {
        clearTimeout(pendingClick);
        pendingClick = null;
      }
    };

    if (editing) {
      body.replaceChild(renameField(snap), subject);
    } else {
      subject.textContent = snap.subject || '(no description)';
      if (snap.head) { item.title = 'Double-click the description to rename it.'; }
      body.addEventListener('dblclick', function (event) {
        event.preventDefault();
        cancelPendingClick();
        renaming = snap.sha;
        redraw();
      });
    }

    var time = item.querySelector('.snap-time');
    time.textContent = relativeTime(snap.time);
    time.title = absoluteTime(snap.time);
    item.querySelector('.snap-sha').textContent = snap.short_sha;

    var extra = (snap.body || '').split('\n').slice(1).join('\n').trim();
    item.querySelector('.snap-detail').textContent = extra;

    // The row itself is the way back to a version. The snapshot already on
    // screen is not clickable — there is nowhere to go.
    if (!snap.head && !editing) {
      item.classList.add('clickable');
      item.title = 'Click to go back to this version. Double-click the description to rename it.';
      item.setAttribute('role', 'button');
      item.tabIndex = 0;

      var restore = function () { bridge('su_restore', snap.sha); };

      item.addEventListener('click', function () {
        if (pendingClick) { return; }
        pendingClick = setTimeout(function () {
          pendingClick = null;
          restore();
        }, 220);
      });

      item.addEventListener('keydown', function (event) {
        if (event.key === 'Enter' || event.key === ' ') {
          event.preventDefault();
          cancelPendingClick();
          restore();
        }
      });
    }

    item.querySelector('.snap-delete').addEventListener('click', function (event) {
      // Without this the row underneath would also fire, and removing a
      // snapshot would restore it on the way out.
      event.stopPropagation();
      cancelPendingClick();
      bridge('su_delete', snap.sha);
    });

    return item;
  }

  function historySection(state) {
    var section = el('div', 'section grow');
    var head = el('div', 'section-head');
    head.appendChild(el('h2', 'section-title', 'Snapshot History'));
    section.appendChild(head);

    if (!state.snapshots || !state.snapshots.length) {
      section.appendChild(el('p', 'empty', 'No snapshots yet. Take one above.'));
      return section;
    }

    var template = document.getElementById('tpl-snapshot');
    var list = el('ul', 'history');
    state.snapshots.forEach(function (snap) {
      list.appendChild(historyRow(template, snap));
    });
    section.appendChild(list);
    return section;
  }

  /* --- settings ---------------------------------------------------------- */

  var checkboxSeq = 0;

  function checkbox(labelText, checked, onChange) {
    var wrapper = el('div', 'form-check');
    var input = document.createElement('input');
    input.type = 'checkbox';
    input.className = 'form-check-input';
    input.id = 'check-' + (checkboxSeq += 1);
    input.checked = !!checked;
    input.addEventListener('change', function () { onChange(input.checked); });

    var label = el('label', 'form-check-label', labelText);
    label.setAttribute('for', input.id);

    wrapper.appendChild(input);
    wrapper.appendChild(label);
    return wrapper;
  }

  // Settings and the folder path are things you set once and then never look
  // at, so they live behind a disclosure instead of taking up permanent room.
  function settingsSection(state) {
    var box = el('details', 'settings');
    box.open = open.settings;
    box.addEventListener('toggle', function () { open.settings = box.open; });

    var summary = document.createElement('summary');
    summary.textContent = 'Settings';
    box.appendChild(summary);

    box.appendChild(checkbox('Snapshot every time I save', state.auto_snapshot, function (checked) {
      bridge('su_set_auto_snapshot', checked);
    }));

    // Without this, "don't ask again" would be a one-way door.
    box.appendChild(checkbox('Ask before removing a snapshot', state.confirm_delete !== false,
      function (checked) { bridge('su_set_confirm_delete', checked); }));

    box.appendChild(checkbox('Show the Snapshot toolbar', state.show_toolbar !== false,
      function (checked) { bridge('su_set_show_toolbar', checked); }));

    if (state.root) {
      var path = el('p', 'path');
      path.appendChild(document.createTextNode('History kept in '));
      path.appendChild(button(state.root, 'btn btn-link btn-sm', function () { bridge('su_reveal'); }));
      box.appendChild(path);
    }

    return box;
  }

  /* --- render ------------------------------------------------------------ */

  function render(state) {
    lastState = state || {};
    state = lastState;
    pendingFocus = null;

    // Preserve where the user was before the DOM is replaced.
    var active = document.activeElement;
    var focusKey = active && active.tagName === 'INPUT' && active.type === 'text'
      ? active.placeholder
      : null;
    var historyEl = app.querySelector('.history');
    var scroll = historyEl ? historyEl.scrollTop : 0;

    while (app.firstChild) { app.removeChild(app.firstChild); }

    var headerEl = header(state);

    if (state.ok === false) {
      app.appendChild(headerEl);
      app.appendChild(notice(state.problem ||
        'Snapshot could not read this model’s history.'));
      return;
    }

    if (!state.saved) {
      app.appendChild(headerEl);
      app.appendChild(notice(
        'Save this model to a folder first — Snapshot keeps its history next to the .skp file.'));
      var section = el('div', 'section');
      section.appendChild(button('Save model as…', 'btn btn-primary btn-sm', function () {
        bridge('su_save_model');
      }));
      app.appendChild(section);
      return;
    }

    if (!state.tracked) {
      app.appendChild(headerEl);
      app.appendChild(notice(
        'This model is not being tracked yet. Snapshot will create a local history folder next to it.'));
      var start = el('div', 'section');
      start.appendChild(button('Start keeping snapshots', 'btn btn-primary btn-sm', function () {
        bridge('su_start_tracking');
      }));
      app.appendChild(start);
      app.appendChild(settingsSection(state));
      return;
    }

    // History is what the panel is read for, so it sits directly under the
    // compose row and takes all the spare height.
    var top = el('div', 'top');
    top.appendChild(headerEl);
    top.appendChild(composeSection(state));
    app.appendChild(top);

    app.appendChild(historySection(state));
    app.appendChild(settingsSection(state));

    // A rename field can only take focus once it is actually in the document.
    if (pendingFocus) {
      pendingFocus.focus();
      pendingFocus.select();
    } else if (focusKey) {
      var inputs = app.querySelectorAll('input[type="text"]');
      for (var i = 0; i < inputs.length; i++) {
        if (inputs[i].placeholder === focusKey) {
          inputs[i].focus();
          inputs[i].setSelectionRange(inputs[i].value.length, inputs[i].value.length);
          break;
        }
      }
    }

    var newHistory = app.querySelector('.history');
    if (newHistory) { newHistory.scrollTop = scroll; }
  }

  // Called from Ruby when the toolbar or a menu item asks for a field rather
  // than opening a dialog of its own.
  function focus(field) {
    if (field === 'variation') {
      namingVariation = true;
      focusVariationField = true;
      redraw();
      return;
    }

    var input = app.querySelector('.compose input');
    if (input) {
      input.focus();
      input.select();
    }
  }

  // Called from Ruby after an automatic snapshot: the generated name arrives
  // selected, so typing replaces it and clicking away keeps it.
  function startRename(sha) {
    namingVariation = false;
    renaming = sha;
    redraw();
  }

  window.SnapshotUI = { render: render, focus: focus, rename: startRename };

  // Re-stamp the "3 minutes ago" labels without bothering Ruby.
  setInterval(function () {
    if (!lastState || !lastState.snapshots) { return; }
    var nodes = app.querySelectorAll('.snap-time');
    for (var i = 0; i < nodes.length && i < lastState.snapshots.length; i++) {
      nodes[i].textContent = relativeTime(lastState.snapshots[i].time);
    }
  }, 30000);

  document.addEventListener('DOMContentLoaded', function () {
    bridge('su_ready');
  });
}());
