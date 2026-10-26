import Foundation
import WebKit

/// The JavaScript the Browser tab injects. Static text compiled into the app (no script is fetched or built
/// at run time), added through `WKUserScript`.
///
/// **Two worlds.** The *inspector* world is an isolated `WKContentWorld`: everything that reads or marks the
/// DOM runs there, and the page's own scripts cannot call it or see its globals. The *page* world (the page's
/// own) has only a recorder of console output and failed requests, because that cannot be seen from an
/// isolated world; the page can see and spoof it, so what it returns is data, never trusted.
@MainActor
enum IDEAIBrowserScripts {
    static let inspectorWorld = WKContentWorld.world(name: "umbra.browser.inspector")
    static let inspectorHandlerName = "umbraInspector"

    /// Adds the scripts and the message handler to a controller. The handler is held strongly by WebKit, so it
    /// must hold what owns the page weakly, and `remove(from:)` must run when the window closes.
    static func install(into controller: WKUserContentController, handler: WKScriptMessageHandler, recorderName: String) {
        controller.add(handler, contentWorld: inspectorWorld, name: inspectorHandlerName)
        // Order matters: the reader adds to the object the core defines.
        for source in [inspector, reader, actions] {
            controller.addUserScript(WKUserScript(
                source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: inspectorWorld))
        }
        controller.addUserScript(WKUserScript(
            source: recorder(name: recorderName), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
    }

    static func remove(from controller: WKUserContentController) {
        controller.removeAllUserScripts()
        controller.removeAllScriptMessageHandlers()
    }

    // MARK: - Page world: console and failed requests

    /// A recorder in the page's own world: it wraps `console.*`, catches uncaught errors and unhandled rejections,
    /// and notes `fetch` / XHR calls that fail or answer 4xx/5xx (URL without its query, status, time: no
    /// headers and no bodies). The entries stay in the page, in a closure; Swift reads them on demand through a
    /// function under a random name. The page can see and spoof all of this, so it is data, never trusted.
    static func recorder(name: String) -> String {
        #"""
        (function () {
          var NAME = '__NAME__';
          if (window[NAME]) return;
          var logs = [], reqs = [], MAX = 200;
          function clip(s, n) { s = String(s == null ? '' : s); return s.length > n ? s.slice(0, n) + '…' : s; }
          function fmt(a) {
            try {
              if (a instanceof Error) return clip(a.stack || a.message || String(a), 800);
              if (typeof a === 'string') return a;
              if (a && a.nodeType === 1) return '<' + a.localName + '>';
              return clip(JSON.stringify(a), 400);
            } catch (e) { return clip(String(a), 200); }
          }
          function push(level, args) {
            try {
              var text = Array.prototype.map.call(args, fmt).join(' ');
              logs.push({ t: Date.now(), level: level, text: clip(text, 1000) });
              if (logs.length > MAX) logs.shift();
            } catch (e) {}
          }
          function bare(u) {
            try { var x = new URL(String(u), location.href); return x.origin + x.pathname + (x.search ? '?…' : ''); } catch (e) { return clip(u, 200); }
          }
          function pushReq(r) { reqs.push(r); if (reqs.length > MAX) reqs.shift(); }
          ['log', 'info', 'warn', 'error', 'debug'].forEach(function (k) {
            var orig = console[k];
            if (typeof orig !== 'function') return;
            console[k] = function () { push(k, arguments); return orig.apply(console, arguments); };
          });
          window.addEventListener('error', function (e) {
            try {
              if (e.target && e.target !== window && e.target.localName) {
                var u = e.target.src || e.target.href;
                if (u) pushReq({ t: Date.now(), method: 'GET', url: bare(u), status: 0, error: 'failed to load <' + e.target.localName + '>', ms: 0 });
                return;
              }
              push('error', ['Uncaught ' + (e.message || 'error') + (e.filename ? ' at ' + bare(e.filename) + ':' + (e.lineno || 0) : '')]);
            } catch (x) {}
          }, true);
          window.addEventListener('unhandledrejection', function (e) { push('error', ['Unhandled promise rejection: ' + fmt(e.reason)]); });
          var f = window.fetch;
          if (typeof f === 'function') {
            window.fetch = function (input, init) {
              var start = Date.now(), url = '', method = 'GET';
              try {
                url = typeof input === 'string' ? input : (input && input.url) || String(input);
                method = ((init && init.method) || (input && input.method) || 'GET').toUpperCase();
              } catch (e) {}
              return f.apply(this, arguments).then(function (r) {
                if (!r.ok) pushReq({ t: Date.now(), method: method, url: bare(url), status: r.status, ms: Date.now() - start });
                return r;
              }, function (err) {
                pushReq({ t: Date.now(), method: method, url: bare(url), status: 0, error: clip(err && err.message || err, 200), ms: Date.now() - start });
                throw err;
              });
            };
          }
          var open = XMLHttpRequest.prototype.open, send = XMLHttpRequest.prototype.send;
          XMLHttpRequest.prototype.open = function (m, u) { this.__umbra = { m: String(m).toUpperCase(), u: u }; return open.apply(this, arguments); };
          XMLHttpRequest.prototype.send = function () {
            var x = this, start = Date.now();
            x.addEventListener('loadend', function () {
              try {
                if (x.__umbra && (x.status === 0 || x.status >= 400)) {
                  pushReq({ t: Date.now(), method: x.__umbra.m, url: bare(x.__umbra.u), status: x.status, ms: Date.now() - start });
                }
              } catch (e) {}
            });
            return send.apply(this, arguments);
          };
          Object.defineProperty(window, NAME, {
            value: function (kind) { return JSON.stringify(kind === 'net' ? reqs : logs); },
            enumerable: false, configurable: false, writable: false
          });
        })();
        """#.replacingOccurrences(of: "__NAME__", with: name)
    }

    // MARK: - Inspector world: reading the page

    /// Adds to `window.__umbra`: a compact outline of the page with stable refs, its text, and one element's
    /// details. Refs live in a map in this world, so the page's DOM is never marked; they die with the document.
    /// Input values are never read: a field is `[empty]` or `[filled]`.
    static let reader = #"""
    (function () {
      'use strict';
      var api = window.__umbra;
      if (!api || api._reader) return;
      var clip = api._clip, squash = api._squash, roleOf = api._roleOf, nameOf = api._nameOf, resolve = api._resolve;
      var refs = new Map(), back = new WeakMap(), counter = 0;
      function refFor(el) {
        var r = back.get(el);
        if (r) return r;
        r = 'e' + (++counter);
        back.set(el, r); refs.set(r, new WeakRef(el));
        return r;
      }
      function byRef(r) { var w = refs.get(r); var el = w && w.deref(); return el && el.isConnected ? el : null; }
      function target(arg) { arg = String(arg || ''); return /^e\d+$/.test(arg) ? byRef(arg) : resolve(arg); }

      var SKIP = { script: 1, style: 1, noscript: 1, template: 1, head: 1, meta: 1, link: 1, title: 1, 'umbra-overlay': 1 };
      var LEAF = { button: 1, link: 1, textbox: 1, searchbox: 1, checkbox: 1, radio: 1, combobox: 1, slider: 1, img: 1, heading: 1,
        progressbar: 1, tab: 1, menuitem: 1, option: 1, switch: 1, spinbutton: 1 };
      var STRUCT = { navigation: 1, main: 1, banner: 1, contentinfo: 1, complementary: 1, form: 1, list: 1, table: 1, dialog: 1,
        region: 1, group: 1, tablist: 1, menu: 1, toolbar: 1 };

      function visible(el) {
        if (el.hidden || el.getAttribute('aria-hidden') === 'true') return false;
        var cs = getComputedStyle(el);
        if (cs.display === 'none' || cs.visibility === 'hidden' || cs.visibility === 'collapse') return false;
        if (cs.display === 'contents') return true;
        var r = el.getBoundingClientRect();
        return r.width > 0 || r.height > 0;
      }
      function pathOf(href) {
        try { var u = new URL(href, location.href); return u.origin === location.origin ? u.pathname : u.host + u.pathname; } catch (e) { return ''; }
      }
      function leafLine(el, role) {
        var name = nameOf(el) || '';
        if (!name && (role === 'link' || role === 'button' || role === 'tab' || role === 'menuitem' || role === 'option')) name = clip(squash(el.textContent), 80);
        var s = role + (name ? ' "' + clip(name, 100) + '"' : '') + ' [ref=' + refFor(el) + ']';
        var tag = el.localName;
        if (role === 'heading') s += ' [level=' + (/^h([1-6])$/.test(tag) ? tag.charAt(1) : (el.getAttribute('aria-level') || '2')) + ']';
        if (el.disabled || el.getAttribute('aria-disabled') === 'true') s += ' [disabled]';
        if (el.checked === true || el.getAttribute('aria-checked') === 'true') s += ' [checked]';
        if (el.getAttribute('aria-expanded')) s += ' [expanded=' + el.getAttribute('aria-expanded') + ']';
        if (el.getAttribute('aria-selected') === 'true') s += ' [selected]';
        if (el.required) s += ' [required]';
        if (tag === 'input' || tag === 'textarea') {
          var type = (el.getAttribute('type') || 'text').toLowerCase();
          if (type === 'password') s += ' [password]';
          else if (type !== 'text' && tag === 'input' && role === 'textbox') s += ' [type=' + type + ']';
          if (role === 'textbox' || role === 'searchbox' || role === 'spinbutton') s += (el.value && el.value.length) ? ' [filled]' : ' [empty]';
        }
        if (tag === 'select' && el.selectedOptions && el.selectedOptions[0]) s += ' [selected="' + clip(squash(el.selectedOptions[0].text), 60) + '"]';
        if (role === 'link' && el.getAttribute('href')) s += ' [href=' + clip(pathOf(el.getAttribute('href')), 100) + ']';
        return s;
      }
      function emit(out, depth, line, st) {
        var text = new Array(Math.min(depth, 8) + 1).join('  ') + '- ' + line;
        out.push(text); st.nodes++; st.chars += text.length;
      }
      function walk(node, depth, out, st) {
        for (var c = node.firstChild; c; c = c.nextSibling) {
          if (st.nodes >= st.max || st.chars >= st.maxChars || st.visited > 5000) { st.truncated = true; return; }
          if (c.nodeType === 3) {
            var t = squash(c.nodeValue);
            if (t) emit(out, depth, 'text "' + clip(t, 120) + '"', st);
            continue;
          }
          if (c.nodeType !== 1) continue;
          st.visited++;
          if (SKIP[c.localName]) continue;
          if (!visible(c)) continue;
          if (c.localName === 'svg') {
            var label = c.getAttribute('aria-label') || '';
            if (label) emit(out, depth, 'img "' + clip(label, 80) + '"', st);
            continue;
          }
          var role = roleOf(c);
          if (role && LEAF[role]) { emit(out, depth, leafLine(c, role), st); continue; }
          if (role && STRUCT[role]) {
            var name = nameOf(c);
            emit(out, depth, role + (name ? ' "' + clip(name, 80) + '"' : '') + ' [ref=' + refFor(c) + ']', st);
            walk(c, depth + 1, out, st);
            continue;
          }
          // A pointer cursor that starts here (children inherit it) is a control built from a plain element.
          var parentCursor = c.parentElement ? getComputedStyle(c.parentElement).cursor : '';
          if (getComputedStyle(c).cursor === 'pointer' && parentCursor !== 'pointer') {
            var label2 = clip(squash(c.textContent), 80);
            if (label2) { emit(out, depth, 'clickable "' + label2 + '" [ref=' + refFor(c) + ']', st); continue; }
          }
          if (c.shadowRoot) walk(c.shadowRoot, depth, out, st);
          walk(c, depth, out, st);
        }
      }

      function scopeRoot(selector) {
        if (!selector) return document.body || document.documentElement;
        return target(selector);
      }

      Object.assign(api, {
        _reader: true,
        snapshot: function (selector, maxNodes, maxChars) {
          var root = scopeRoot(selector);
          if (!root) return JSON.stringify({ error: selector ? 'Nothing matches ' + selector + ' on this page now.' : 'The page has no body yet.' });
          var out = [], st = { nodes: 0, chars: 0, max: maxNodes || 400, maxChars: maxChars || 20000, visited: 0, truncated: false };
          if (root !== document.body && root !== document.documentElement) {
            var role = roleOf(root);
            emit(out, 0, (role || root.localName) + ' [ref=' + refFor(root) + ']', st);
            walk(root, 1, out, st);
          } else {
            walk(root, 0, out, st);
          }
          return JSON.stringify({
            url: String(location.href), title: document.title || '',
            viewport: { w: window.innerWidth, h: window.innerHeight },
            scrollY: Math.round(window.scrollY), height: Math.round(document.documentElement.scrollHeight),
            outline: out.join('\n'), count: st.nodes, truncated: st.truncated, ready: document.readyState
          });
        },
        text: function (selector, maxChars) {
          var root = scopeRoot(selector);
          if (!root) return JSON.stringify({ error: selector ? 'Nothing matches ' + selector + ' on this page now.' : 'The page has no body yet.' });
          var limit = maxChars || 12000, parts = [], total = 0, truncated = false;
          var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
            acceptNode: function (n) {
              var p = n.parentElement;
              if (!p || SKIP[p.localName] || p.localName === 'textarea' || p.localName === 'option') return NodeFilter.FILTER_REJECT;
              return squash(n.nodeValue) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
            }
          });
          var cache = new Map(), n;
          while ((n = walker.nextNode())) {
            var p = n.parentElement;
            if (!cache.has(p)) cache.set(p, visible(p));
            if (!cache.get(p)) continue;
            var t = squash(n.nodeValue);
            if (total + t.length > limit) { truncated = true; break; }
            parts.push(t); total += t.length + 1;
          }
          return JSON.stringify({ url: String(location.href), title: document.title || '', text: parts.join('\n'), truncated: truncated });
        },
        inspect: function (arg) {
          var el = target(arg);
          if (!el) return JSON.stringify({ error: /^e\d+$/.test(String(arg)) ? 'That ref is gone: the page changed or navigated. Take a new snapshot.' : 'Nothing matches ' + arg + ' on this page now.' });
          var attrs = {}, count = 0;
          for (var i = 0; i < el.attributes.length && count < 30; i++) {
            var a = el.attributes[i];
            if (/^on/i.test(a.name)) continue;
            if (a.name === 'value' && (el.localName === 'input' || el.localName === 'textarea' || el.localName === 'select')) continue;
            attrs[a.name] = clip(a.value, 100); count++;
          }
          var r = el.getBoundingClientRect();
          var d = api._describe(el);
          return JSON.stringify({
            ref: refFor(el), element: d, attributes: attrs, visible: visible(el),
            inViewport: r.bottom > 0 && r.right > 0 && r.top < window.innerHeight && r.left < window.innerWidth,
            box: { x: Math.round(r.left), y: Math.round(r.top), w: Math.round(r.width), h: Math.round(r.height),
                   scrollW: el.scrollWidth, scrollH: el.scrollHeight },
            children: el.children.length
          });
        },
        _byRef: byRef, _target: target, _refFor: refFor, _visible: visible
      });
    })();
    """#

    // MARK: - Inspector world: acting on the page

    /// Adds `act` to `window.__umbra`: click, type, select, press and scroll, as DOM events on an element found by
    /// ref or selector. Typing into a password, card or one-time-code field is refused here, whatever the caller
    /// says. No function evaluates text as code: the agent cannot run JavaScript, only these actions.
    static let actions = #"""
    (function () {
      'use strict';
      var api = window.__umbra;
      if (!api || api._actions) return;
      var squash = api._squash, clip = api._clip;

      function fail(message) { return JSON.stringify({ error: message }); }
      function done(message) { return JSON.stringify({ ok: true, message: message, url: String(location.href) }); }
      function find(arg) { return api._target(arg); }
      function goneMessage(arg) {
        return /^e\d+$/.test(String(arg)) ? 'That ref is gone: the page changed or navigated. Take a new snapshot.' : 'Nothing matches ' + arg + ' on this page now.';
      }
      function label(el) {
        var role = api._roleOf(el) || el.localName, name = api._nameOf(el) || clip(squash(el.textContent), 60);
        return role + (name ? ' "' + name + '"' : '');
      }
      function mouse(el, type) {
        el.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, composed: true, view: window, button: 0 }));
      }
      function pointer(el, type) {
        try { el.dispatchEvent(new PointerEvent(type, { bubbles: true, cancelable: true, composed: true, pointerType: 'mouse', isPrimary: true })); } catch (e) {}
      }
      function reveal(el) {
        try { el.scrollIntoView({ block: 'center', inline: 'nearest' }); } catch (e) {}
        api._flashNode(el);
      }
      function input(el) {
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      }
      var NOT_TEXT = ['checkbox', 'radio', 'button', 'submit', 'reset', 'file', 'image', 'range', 'color', 'hidden'];
      var KEYS = { Enter: 13, Escape: 27, ArrowUp: 38, ArrowDown: 40, ArrowLeft: 37, ArrowRight: 39, Home: 36, End: 35,
        PageUp: 33, PageDown: 34, Backspace: 8, Delete: 46, ' ': 32, Space: 32 };

      var act = {
        click: function (arg) {
          var el = find(arg);
          if (!el) return fail(goneMessage(arg));
          if (!api._visible(el)) return fail('That element is not visible, so it cannot be clicked.');
          if (el.disabled || el.getAttribute('aria-disabled') === 'true') return fail('That element is disabled.');
          var what = label(el);
          reveal(el);
          pointer(el, 'pointerover'); mouse(el, 'mouseover');
          pointer(el, 'pointerdown'); mouse(el, 'mousedown');
          if (el.focus) { try { el.focus({ preventScroll: true }); } catch (e) {} }
          pointer(el, 'pointerup'); mouse(el, 'mouseup');
          el.click();
          return done('Clicked ' + what + '.');
        },
        type: function (arg, text, submit, clear) {
          var el = find(arg);
          if (!el) return fail(goneMessage(arg));
          text = String(text == null ? '' : text);
          if (text.length > 2000) return fail('That text is longer than 2,000 characters.');
          if (api._isSecret(el)) return fail('That is a password, card or one-time-code field. Typing into it is refused: ask the user to fill it in.');
          var tag = el.localName, what = label(el);
          if (tag === 'input' || tag === 'textarea') {
            var type = (el.getAttribute('type') || 'text').toLowerCase();
            if (NOT_TEXT.indexOf(type) >= 0) return fail('That is not a text field (' + type + '). Use click or select.');
            if (el.disabled || el.readOnly) return fail('That field is not editable.');
            reveal(el);
            el.focus();
            var proto = tag === 'textarea' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
            var setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
            setter.call(el, clear ? text : String(el.value || '') + text);
            input(el);
          } else if (el.isContentEditable) {
            reveal(el);
            el.focus();
            if (clear) document.execCommand('selectAll');
            document.execCommand('insertText', false, text);
          } else {
            return fail('That element is not a field you can type into.');
          }
          if (submit) {
            var form = el.form;
            ['keydown', 'keypress', 'keyup'].forEach(function (t) {
              el.dispatchEvent(new KeyboardEvent(t, { key: 'Enter', code: 'Enter', keyCode: 13, bubbles: true, cancelable: true }));
            });
            if (form && form.requestSubmit) { try { form.requestSubmit(); } catch (e) {} }
          }
          return done('Typed ' + text.length + ' character' + (text.length === 1 ? '' : 's') + ' into ' + what + (submit ? ' and pressed Enter.' : '.'));
        },
        select: function (arg, value) {
          var el = find(arg);
          if (!el) return fail(goneMessage(arg));
          var what = label(el);
          value = String(value == null ? '' : value);
          if (el.localName === 'select') {
            var options = Array.prototype.slice.call(el.options), wanted = value.toLowerCase(), found = null;
            options.forEach(function (o) { if (!found && (o.value === value || squash(o.text) === value)) found = o; });
            options.forEach(function (o) { if (!found && (o.value.toLowerCase() === wanted || squash(o.text).toLowerCase() === wanted)) found = o; });
            if (!found) return fail('No option "' + value + '". Options: ' + options.slice(0, 12).map(function (o) { return '"' + squash(o.text) + '"'; }).join(', '));
            reveal(el);
            el.value = found.value;
            input(el);
            return done('Selected "' + squash(found.text) + '" in ' + what + '.');
          }
          var type = (el.getAttribute('type') || '').toLowerCase();
          if (type === 'checkbox' || type === 'radio') {
            reveal(el);
            var want = !/^(false|off|no|0)$/i.test(value);
            if (type === 'radio' || el.checked !== want) el.click();
            return done((el.checked ? 'Checked ' : 'Unchecked ') + what + '.');
          }
          return fail('That element is not a select, checkbox or radio button.');
        },
        press: function (arg, key) {
          key = String(key || '');
          if (key === 'Tab') return fail('Tab is not supported. Click the element you want instead.');
          if (!(key in KEYS)) return fail('Unsupported key "' + key + '". Use ' + Object.keys(KEYS).join(', ') + '.');
          var el = arg ? find(arg) : (document.activeElement || document.body);
          if (!el) return fail(goneMessage(arg));
          if (arg) { reveal(el); try { el.focus(); } catch (e) {} }
          var init = { key: key === 'Space' ? ' ' : key, code: key === ' ' || key === 'Space' ? 'Space' : key, keyCode: KEYS[key], bubbles: true, cancelable: true };
          var proceed = el.dispatchEvent(new KeyboardEvent('keydown', init));
          if (key === 'Enter') el.dispatchEvent(new KeyboardEvent('keypress', init));
          el.dispatchEvent(new KeyboardEvent('keyup', init));
          if (key === 'Enter' && proceed && el.form && el.localName === 'input' && el.form.requestSubmit) { try { el.form.requestSubmit(); } catch (e) {} }
          return done('Pressed ' + key + (arg ? ' on ' + label(el) : '') + '.');
        },
        scroll: function (arg, direction, amount) {
          if (arg) {
            var el = find(arg);
            if (!el) return fail(goneMessage(arg));
            reveal(el);
            return done('Scrolled ' + label(el) + ' into view.');
          }
          var step = amount && amount > 0 ? amount : Math.round(window.innerHeight * 0.8);
          if (direction === 'top') window.scrollTo(0, 0);
          else if (direction === 'bottom') window.scrollTo(0, document.documentElement.scrollHeight);
          else if (direction === 'up') window.scrollBy(0, -step);
          else window.scrollBy(0, step);
          return done('Scrolled to ' + Math.round(window.scrollY) + ' of ' + Math.round(document.documentElement.scrollHeight) + ' px.');
        },
        text: function () { return JSON.stringify({ text: document.body ? squash(document.body.innerText || '') : '' }); }
      };
      api.act = act;
      api._actions = true;
    })();
    """#

    // MARK: - Page world: framework component names

    /// A function body (variable `selector`) run in the page's own world: frameworks keep the component behind
    /// a DOM node in properties that an isolated world cannot see. Only reads, returns plain text, and the answer is
    /// page data like everything else here.
    static let componentHint = #"""
    function find(sel) {
      try {
        var ctx = document, el = null, segs = String(sel).split(' >>> ');
        for (var i = 0; i < segs.length; i++) {
          el = ctx.querySelector(segs[i]);
          if (!el) return null;
          if (i < segs.length - 1) { ctx = el.shadowRoot; if (!ctx) return null; }
        }
        return el;
      } catch (e) { return null; }
    }
    var el = find(selector);
    if (!el) return '';
    try {
      var keys = Object.keys(el);
      var fk = null;
      for (var i = 0; i < keys.length; i++) {
        if (keys[i].indexOf('__reactFiber$') === 0 || keys[i].indexOf('__reactInternalInstance$') === 0) { fk = keys[i]; break; }
      }
      if (fk) {
        var f = el[fk], hops = 0, names = [], src = null;
        while (f && hops++ < 40) {
          var t = f.type;
          if (t && typeof t !== 'string') {
            var n = t.displayName || t.name || (t.render && (t.render.displayName || t.render.name));
            if (n) { names.push(String(n)); if (!src && f._debugSource) src = f._debugSource.fileName + ':' + f._debugSource.lineNumber; }
          }
          if (names.length >= 3) break;
          f = f.return;
        }
        if (names.length) return 'React: ' + names.join(' < ') + (src ? ' (' + src + ')' : '');
      }
      var vc = el.__vueParentComponent;
      if (vc) { var vt = vc.type || {}; return 'Vue: ' + (vt.__name || vt.name || 'anonymous') + (vt.__file ? ' (' + vt.__file + ')' : ''); }
      if (el.__vue__) { var v = el.__vue__; return 'Vue 2: ' + ((v.$options && (v.$options.name || v.$options._componentTag)) || 'anonymous'); }
      if (el.__svelte_meta && el.__svelte_meta.loc) { var l = el.__svelte_meta.loc; return 'Svelte: ' + l.file + ':' + l.line; }
      if (window.ng && window.ng.getComponent) { var c = window.ng.getComponent(el); if (c) return 'Angular: ' + (c.constructor && c.constructor.name); }
    } catch (e) {}
    return '';
    """#

    // MARK: - Inspector world: overlay, picker, pins, element capture

    /// `window.__umbra` in the inspector world. It speaks to Swift through one message handler (JSON text) and
    /// is driven from Swift with `callJavaScript`. The overlay is a closed shadow root with no inputs: notes are
    /// written in a native popover, so no keystroke ever reaches the page's own hotkey listeners.
    static let inspector = #"""
    (function () {
      'use strict';
      if (window.__umbra) return;

      function post(obj) {
        try { window.webkit.messageHandlers.umbraInspector.postMessage(JSON.stringify(obj)); } catch (e) {}
      }
      var MAX_HTML = 1500, MAX_TEXT = 200;
      function clip(s, n) { s = String(s == null ? '' : s); return s.length > n ? s.slice(0, n) + '…' : s; }
      function squash(s) { return String(s == null ? '' : s).replace(/\s+/g, ' ').trim(); }
      function esc(s) { return (window.CSS && CSS.escape) ? CSS.escape(s) : String(s).replace(/[^a-zA-Z0-9_-]/g, '\\$&'); }

      var state = {
        picking: false, hovered: null, chain: [], draftEl: null,
        notes: [], pins: new Map(), host: null, layer: null, hoverBox: null, hoverTag: null, selBox: null, flashBox: null,
        prevCursor: null, timer: 0, raf: 0, missingKey: ''
      };

      // ---------- selectors ----------
      function uniqueIn(root, sel, el) {
        try { var found = root.querySelectorAll(sel); return found.length === 1 && found[0] === el; } catch (e) { return false; }
      }
      function stableClass(c) {
        if (!c || c.length > 40) return false;
        if (/^css-/.test(c) || /^(sc|jsx|svelte|ng|_)-/.test(c)) return false;
        if (/\d{3,}/.test(c)) return false;
        if (/^[a-z]{1,3}-[A-Za-z0-9]{5,}$/.test(c)) return false;
        return true;
      }
      var TEST_ATTRS = ['data-testid', 'data-test', 'data-cy', 'data-qa'];
      function selectorIn(el, root) {
        if (el.id) { var s0 = '#' + esc(el.id); if (uniqueIn(root, s0, el)) return s0; }
        var parts = [], node = el;
        while (node && node.nodeType === 1) {
          var part = node.localName, tid = null;
          for (var i = 0; i < TEST_ATTRS.length; i++) {
            var v = node.getAttribute(TEST_ATTRS[i]);
            if (v) { tid = '[' + TEST_ATTRS[i] + '="' + v.replace(/["\\]/g, '\\$&') + '"]'; break; }
          }
          if (tid) {
            part += tid;
          } else {
            var cls = Array.prototype.filter.call(node.classList, stableClass).slice(0, 2);
            if (cls.length) part += '.' + cls.map(esc).join('.');
            var parent = node.parentElement;
            if (parent) {
              var same = 0;
              for (var k = 0; k < parent.children.length; k++) {
                var sib = parent.children[k];
                try { if (sib.matches(part)) same++; } catch (e) {}
              }
              if (same > 1) {
                var n = 1, prev = node.previousElementSibling;
                while (prev) { if (prev.localName === node.localName) n++; prev = prev.previousElementSibling; }
                part += ':nth-of-type(' + n + ')';
              }
            }
          }
          parts.unshift(part);
          var sel = parts.join(' > ');
          if (uniqueIn(root, sel, el)) return sel;
          node = node.parentElement;
        }
        return parts.join(' > ');
      }
      function selectorFor(el) {
        var segs = [], node = el, guard = 0;
        while (node && guard++ < 8) {
          var root = node.getRootNode();
          segs.unshift(selectorIn(node, root));
          if (root && root.host && root.nodeType === 11) node = root.host; else break;
        }
        return segs.join(' >>> ');
      }
      function resolve(sel) {
        if (!sel) return null;
        try {
          var ctx = document, el = null, segs = String(sel).split(' >>> ');
          for (var i = 0; i < segs.length; i++) {
            el = ctx.querySelector(segs[i]);
            if (!el) return null;
            if (i < segs.length - 1) { ctx = el.shadowRoot; if (!ctx) return null; }
          }
          return el;
        } catch (e) { return null; }
      }
      function fuzzy(note) {
        if (!note || !note.tag) return null;
        var hint = squash(note.text || '').slice(0, 40), list;
        try { list = document.querySelectorAll(note.tag); } catch (e) { return null; }
        if (!hint) return null;
        for (var i = 0; i < list.length; i++) {
          if (squash(list[i].textContent).indexOf(hint) === 0) return list[i];
        }
        return null;
      }

      // ---------- roles, names, description ----------
      var ROLES = { a: 'link', button: 'button', nav: 'navigation', main: 'main', header: 'banner', footer: 'contentinfo',
        aside: 'complementary', ul: 'list', ol: 'list', li: 'listitem', table: 'table', img: 'img', select: 'combobox',
        textarea: 'textbox', form: 'form', h1: 'heading', h2: 'heading', h3: 'heading', h4: 'heading', h5: 'heading',
        h6: 'heading', dialog: 'dialog', summary: 'button', details: 'group', progress: 'progressbar', section: 'region' };
      function roleOf(el) {
        var r = el.getAttribute && el.getAttribute('role');
        if (r) return r.split(' ')[0];
        var t = el.localName;
        if (t === 'a') return el.hasAttribute('href') ? 'link' : null;
        if (t === 'input') {
          var type = (el.getAttribute('type') || 'text').toLowerCase();
          if (type === 'checkbox') return 'checkbox';
          if (type === 'radio') return 'radio';
          if (type === 'button' || type === 'submit' || type === 'reset') return 'button';
          if (type === 'range') return 'slider';
          if (type === 'search') return 'searchbox';
          return 'textbox';
        }
        return ROLES[t] || null;
      }
      function nameOf(el) {
        try {
          var a = el.getAttribute('aria-label');
          if (a) return clip(squash(a), 100);
          var by = el.getAttribute('aria-labelledby');
          if (by) {
            var text = by.split(/\s+/).map(function (id) { var n = document.getElementById(id); return n ? n.textContent : ''; }).join(' ');
            if (squash(text)) return clip(squash(text), 100);
          }
          if (el.localName === 'img') return clip(squash(el.getAttribute('alt') || ''), 100) || null;
          if (el.id) {
            var lab = document.querySelector('label[for="' + esc(el.id) + '"]');
            if (lab && squash(lab.textContent)) return clip(squash(lab.textContent), 100);
          }
          var t = el.localName;
          if (t === 'input') {
            var type = (el.getAttribute('type') || 'text').toLowerCase();
            if (type === 'button' || type === 'submit' || type === 'reset') return clip(squash(el.getAttribute('value') || ''), 100) || null;
            return clip(squash(el.getAttribute('placeholder') || el.getAttribute('name') || ''), 100) || null;
          }
          if (t === 'button' || t === 'a' || t === 'summary' || /^h[1-6]$/.test(t) || el.getAttribute('role') === 'button') {
            return clip(squash(el.textContent), 100) || clip(squash(el.getAttribute('title') || ''), 100) || null;
          }
          return clip(squash(el.getAttribute('title') || ''), 100) || null;
        } catch (e) { return null; }
      }
      var STYLE_KEYS = ['display', 'position', 'width', 'height', 'margin', 'padding', 'color', 'background-color', 'font-family',
        'font-size', 'font-weight', 'line-height', 'border', 'border-radius', 'box-shadow', 'opacity', 'z-index', 'overflow',
        'flex-direction', 'justify-content', 'align-items', 'gap', 'grid-template-columns'];
      function stylesOf(el) {
        var out = {};
        try {
          var cs = getComputedStyle(el);
          for (var i = 0; i < STYLE_KEYS.length; i++) {
            var v = cs.getPropertyValue(STYLE_KEYS[i]);
            if (v && v !== 'none' && v !== 'normal' && v !== 'auto' && v !== '0px' && v !== 'visible' && v !== 'static') out[STYLE_KEYS[i]] = clip(v, 120);
          }
        } catch (e) {}
        return out;
      }
      function isSecret(el) {
        var t = el.localName;
        if (t !== 'input' && t !== 'textarea' && t !== 'select') return false;
        var type = (el.getAttribute('type') || '').toLowerCase();
        var ac = (el.getAttribute('autocomplete') || '').toLowerCase();
        return type === 'password' || /^cc-/.test(ac) || ac === 'one-time-code' || ac === 'current-password' || ac === 'new-password';
      }
      function sanitizedHTML(el) {
        var redactions = 0;
        var clone = el.cloneNode(true);
        function scrub(node) {
          if (node.nodeType !== 1) return;
          var tag = node.localName;
          if (tag === 'script' || tag === 'noscript' || tag === 'style') node.textContent = '';
          if (tag === 'textarea' && node.textContent) { node.textContent = ''; redactions++; }
          if ((tag === 'input' || tag === 'select' || tag === 'textarea') && node.hasAttribute('value')) { node.setAttribute('value', ''); redactions++; }
          var attrs = Array.prototype.slice.call(node.attributes);
          for (var i = 0; i < attrs.length; i++) { if (/^on/i.test(attrs[i].name)) node.removeAttribute(attrs[i].name); }
          for (var j = 0; j < node.children.length; j++) scrub(node.children[j]);
        }
        scrub(clone);
        return { html: clip(clone.outerHTML, MAX_HTML), redactions: redactions };
      }
      function shortName(el) {
        var s = el.localName;
        if (el.id) s += '#' + el.id;
        else if (el.classList && el.classList.length) s += '.' + el.classList[0];
        return s;
      }
      function ancestorsOf(el) {
        var out = [], n = el.parentElement;
        while (n && out.length < 5 && n !== document.documentElement) { out.push(shortName(n)); n = n.parentElement; }
        return out;
      }
      function pageRect(el) {
        var r = el.getBoundingClientRect();
        return { x: Math.round(r.left + window.scrollX), y: Math.round(r.top + window.scrollY), w: Math.round(r.width), h: Math.round(r.height) };
      }
      function viewRect(el) {
        var r = el.getBoundingClientRect();
        return { x: r.left, y: r.top, w: r.width, h: r.height };
      }
      function describe(el) {
        var secret = isSecret(el);
        var h = sanitizedHTML(el);
        var text = '';
        if (!secret && el.localName !== 'input' && el.localName !== 'textarea' && el.localName !== 'select') {
          text = clip(squash(el.innerText || el.textContent), MAX_TEXT);
        }
        return {
          selector: selectorFor(el), tag: el.localName, id: el.id || null,
          classes: Array.prototype.slice.call(el.classList || [], 0, 20),
          role: roleOf(el), label: secret ? null : nameOf(el), text: text,
          html: secret ? '<' + el.localName + ' …>' : h.html, rect: pageRect(el), styles: stylesOf(el),
          ancestors: ancestorsOf(el), redactions: h.redactions + (secret ? 1 : 0), component: null
        };
      }

      // ---------- overlay ----------
      var CSS_TEXT = [
        ':host{all:initial}',
        '.layer{position:fixed;left:0;top:0;right:0;bottom:0;pointer-events:none;font:12px -apple-system,system-ui,sans-serif}',
        '.box{position:fixed;box-sizing:border-box;border:2px solid #0a84ff;background:rgba(10,132,255,.14);border-radius:3px;display:none}',
        '.box.sel{border-color:#ff9f0a;background:rgba(255,159,10,.16)}',
        '.box.flash{border-color:#30d158;background:rgba(48,209,88,.2)}',
        '.tag{position:fixed;display:none;background:#0a84ff;color:#fff;padding:2px 6px;border-radius:4px;white-space:nowrap;max-width:70vw;overflow:hidden;text-overflow:ellipsis;font:11px ui-monospace,Menlo,monospace}',
        '.pin{position:fixed;width:20px;height:20px;border-radius:10px;background:#ff9f0a;color:#1c1c1e;font-weight:700;display:flex;align-items:center;justify-content:center;pointer-events:auto;cursor:pointer;box-shadow:0 1px 4px rgba(0,0,0,.45);font-size:11px;line-height:20px}',
        '.pin.agent{background:#bf5af2;color:#fff}',
        '.pin.addressed{background:#30d158}',
        '.pin.missing{opacity:.45}'
      ].join('\n');

      function el(tag, cls) { var n = document.createElement(tag); if (cls) n.className = cls; return n; }
      function ensureHost() {
        if (state.host && state.host.isConnected) return true;
        var root = document.documentElement;
        if (!root) return false;
        var host = document.createElement('umbra-overlay');
        var s = host.style;
        s.setProperty('all', 'initial', 'important');
        s.setProperty('position', 'fixed', 'important');
        s.setProperty('left', '0', 'important'); s.setProperty('top', '0', 'important');
        s.setProperty('width', '0', 'important'); s.setProperty('height', '0', 'important');
        s.setProperty('z-index', '2147483647', 'important');
        s.setProperty('pointer-events', 'none', 'important');
        var shadow = host.attachShadow({ mode: 'closed' });
        try {
          var sheet = new CSSStyleSheet();
          sheet.replaceSync(CSS_TEXT);
          shadow.adoptedStyleSheets = [sheet];
        } catch (e) {
          var st = document.createElement('style'); st.textContent = CSS_TEXT; shadow.appendChild(st);
        }
        var layer = el('div', 'layer');
        state.hoverBox = el('div', 'box'); state.selBox = el('div', 'box sel'); state.flashBox = el('div', 'box flash');
        state.hoverTag = el('div', 'tag');
        layer.appendChild(state.hoverBox); layer.appendChild(state.selBox); layer.appendChild(state.flashBox); layer.appendChild(state.hoverTag);
        shadow.appendChild(layer);
        root.appendChild(host);
        state.host = host; state.layer = layer;
        // Pins made before the host existed (or one lost with a rebuilt document element) go back in.
        state.pins.forEach(function (pin) { layer.appendChild(pin.node); });
        return true;
      }
      function place(box, r) {
        box.style.left = r.left + 'px'; box.style.top = r.top + 'px';
        box.style.width = r.width + 'px'; box.style.height = r.height + 'px';
        box.style.display = 'block';
      }
      function target(e) {
        var p = e.composedPath ? e.composedPath() : null;
        var t = p && p.length ? p[0] : e.target;
        return t && t.nodeType === 1 ? t : (t && t.parentElement) || null;
      }
      function setHover(node) {
        if (!node || !ensureHost()) return;
        state.hovered = node;
        var r = node.getBoundingClientRect();
        place(state.hoverBox, r);
        var label = shortName(node) + '  ' + Math.round(r.width) + '×' + Math.round(r.height);
        state.hoverTag.textContent = label;
        state.hoverTag.style.display = 'block';
        state.hoverTag.style.left = Math.max(0, Math.min(r.left, window.innerWidth - 160)) + 'px';
        state.hoverTag.style.top = (r.top > 22 ? r.top - 22 : r.bottom + 2) + 'px';
      }
      function hideHover() {
        state.hovered = null; state.chain = [];
        if (state.hoverBox) state.hoverBox.style.display = 'none';
        if (state.hoverTag) state.hoverTag.style.display = 'none';
      }
      function showSel(node) {
        if (!ensureHost()) return;
        if (!node) { state.selBox.style.display = 'none'; return; }
        place(state.selBox, node.getBoundingClientRect());
      }
      function setCursor(on) {
        var root = document.documentElement;
        if (!root) return;
        if (on) {
          if (state.prevCursor === null) state.prevCursor = root.style.getPropertyValue('cursor') + '|' + root.style.getPropertyPriority('cursor');
          root.style.setProperty('cursor', 'crosshair', 'important');
        } else if (state.prevCursor !== null) {
          var parts = state.prevCursor.split('|');
          if (parts[0]) root.style.setProperty('cursor', parts[0], parts[1]); else root.style.removeProperty('cursor');
          state.prevCursor = null;
        }
      }

      var flashTimer = 0;
      function flashNode(node) {
        if (!ensureHost()) return;
        place(state.flashBox, node.getBoundingClientRect());
        clearTimeout(flashTimer);
        flashTimer = setTimeout(function () { if (state.flashBox) state.flashBox.style.display = 'none'; }, 1200);
      }

      // ---------- picking ----------
      function swallow(e) { e.preventDefault(); e.stopImmediatePropagation(); }
      function pick(node) {
        if (!node) return;
        state.draftEl = node;
        showSel(node);
        post({ t: 'picked', element: describe(node), vr: viewRect(node) });
      }
      function climb(delta) {
        var cur = state.hovered;
        if (!cur) return 'none';
        if (delta < 0) {
          var p = cur.parentElement || (cur.getRootNode && cur.getRootNode().host) || null;
          if (p && p !== document.documentElement) { state.chain.push(cur); setHover(p); }
        } else if (state.chain.length) {
          setHover(state.chain.pop());
        } else {
          for (var i = 0; i < cur.children.length; i++) {
            var r = cur.children[i].getBoundingClientRect();
            if (r.width > 0 && r.height > 0) { setHover(cur.children[i]); break; }
          }
        }
        return 'ok';
      }
      window.addEventListener('mousemove', function (e) {
        if (!state.picking) return;
        var t = target(e);
        if (!t || t === state.host) return;
        if (t !== state.hovered) { state.chain = []; setHover(t); }
      }, true);
      ['pointerdown', 'pointerup', 'mousedown', 'mouseup', 'dblclick', 'contextmenu', 'auxclick'].forEach(function (type) {
        window.addEventListener(type, function (e) {
          if (!state.picking) return;
          var t = target(e);
          if (t === state.host) return;
          swallow(e);
        }, true);
      });
      window.addEventListener('click', function (e) {
        if (!state.picking) return;
        var t = target(e);
        if (t === state.host) return;
        swallow(e);
        pick(state.hovered || t);
      }, true);
      window.addEventListener('keydown', function (e) {
        if (!state.picking) return;
        if (e.key === 'Escape') { swallow(e); api.setPicking(false); post({ t: 'pickEnded' }); }
        else if (e.key === 'ArrowUp') { swallow(e); climb(-1); }
        else if (e.key === 'ArrowDown') { swallow(e); climb(1); }
        else if (e.key === 'Enter' && state.hovered) { swallow(e); pick(state.hovered); }
      }, true);

      // ---------- pins ----------
      function findFor(note) { return resolve(note.selector) || fuzzy(note); }
      function renderPins() {
        if (!state.notes.length && !state.pins.size) return;
        if (!ensureHost()) return;
        var keep = {};
        var gone = [];
        state.notes.forEach(function (note) {
          keep[note.id] = true;
          var pin = state.pins.get(note.id);
          if (!pin) {
            var node = el('div', 'pin');
            node.addEventListener('click', function (ev) {
              ev.preventDefault(); ev.stopPropagation();
              var p = state.pins.get(note.id);
              post({ t: 'pin', id: note.id, vr: p && p.el && p.el.isConnected ? viewRect(p.el) : { x: 40, y: 40, w: 20, h: 20 } });
            });
            state.layer.appendChild(node);
            pin = { node: node, el: null };
            state.pins.set(note.id, pin);
          }
          pin.note = note;
          pin.node.textContent = String(note.number);
          pin.node.className = 'pin' + (note.author === 'agent' ? ' agent' : '') + (note.status === 'addressed' ? ' addressed' : '');
          pin.node.title = note.note || '';
          if (!pin.el || !pin.el.isConnected) pin.el = findFor(note);
        });
        state.pins.forEach(function (pin, id) { if (!keep[id]) { gone.push(id); if (pin.node.parentNode) pin.node.parentNode.removeChild(pin.node); } });
        gone.forEach(function (id) { state.pins.delete(id); });
        positionPins();
        scheduleTimer();
      }
      function positionPins() {
        var missing = [];
        state.pins.forEach(function (pin, id) {
          if (pin.el && !pin.el.isConnected) pin.el = findFor(pin.note);
          if (!pin.el) { pin.node.style.display = 'none'; missing.push(id); return; }
          var r = pin.el.getBoundingClientRect();
          if (r.width === 0 && r.height === 0) { pin.node.style.display = 'none'; return; }
          pin.node.classList.remove('missing');
          pin.node.style.display = 'flex';
          pin.node.style.left = Math.max(0, Math.min(r.left - 8, window.innerWidth - 20)) + 'px';
          pin.node.style.top = Math.max(0, Math.min(r.top - 8, window.innerHeight - 20)) + 'px';
        });
        var key = missing.sort().join(',');
        if (key !== state.missingKey) { state.missingKey = key; post({ t: 'missing', ids: missing }); }
        if (state.selBox && state.draftEl && state.draftEl.isConnected) showSel(state.draftEl);
      }
      function schedule() {
        if (state.raf) return;
        state.raf = requestAnimationFrame(function () { state.raf = 0; positionPins(); });
      }
      function scheduleTimer() {
        if (state.pins.size && !state.timer) state.timer = setInterval(schedule, 600);
        else if (!state.pins.size && state.timer) { clearInterval(state.timer); state.timer = 0; }
      }
      window.addEventListener('scroll', schedule, { capture: true, passive: true });
      window.addEventListener('resize', schedule, { passive: true });
      var mutationTimer = 0;
      try {
        new MutationObserver(function () {
          if (!state.pins.size) return;
          clearTimeout(mutationTimer);
          mutationTimer = setTimeout(function () {
            state.pins.forEach(function (pin) { if (!pin.el || !pin.el.isConnected) pin.el = findFor(pin.note); });
            schedule();
          }, 200);
        }).observe(document, { childList: true, subtree: true });
      } catch (e) {}

      // ---------- API (driven from Swift) ----------
      var api = {
        setPicking: function (on) {
          state.picking = !!on;
          if (state.picking) { ensureHost(); setCursor(true); }
          else { hideHover(); setCursor(false); }
          return 'ok';
        },
        climb: climb,
        clearDraft: function () { state.draftEl = null; if (state.selBox) state.selBox.style.display = 'none'; return 'ok'; },
        sync: function (json) {
          try { state.notes = JSON.parse(json) || []; } catch (e) { return 'bad'; }
          renderPins();
          return 'ok';
        },
        flash: function (id) {
          var pin = state.pins.get(id);
          var node = pin && pin.el && pin.el.isConnected ? pin.el : null;
          if (!node) return 'missing';
          try { node.scrollIntoView({ block: 'center', inline: 'nearest' }); } catch (e) {}
          flashNode(node);
          schedule();
          return 'ok';
        },
        describe: function (sel) { var n = resolve(sel); return n ? JSON.stringify(describe(n)) : null; },
        state: function () {
          return JSON.stringify({
            picking: state.picking, hovered: state.hovered ? selectorFor(state.hovered) : null,
            draft: state.draftEl ? selectorFor(state.draftEl) : null,
            pins: Array.from(state.pins.keys()), hasHost: !!(state.host && state.host.isConnected)
          });
        },
        _resolve: resolve, _describe: describe, _selectorFor: selectorFor, _roleOf: roleOf, _nameOf: nameOf, _clip: clip, _squash: squash,
        _isSecret: isSecret, _flashNode: flashNode
      };
      Object.defineProperty(window, '__umbra', { value: api, enumerable: false, configurable: false, writable: false });

      function ready() { post({ t: 'ready', url: String(location.href) }); }
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', ready); else ready();
    })();
    """#
}
