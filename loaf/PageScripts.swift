import Foundation
import WebKit

enum PageScripts {
    static let passwordWorld: WKContentWorld = {
        if #available(macOS 27.0, *) {
            let configuration = WKContentWorld.Configuration()
            configuration.autofillScriptingEnabled = true
            return WKContentWorld(configuration: configuration)
        }
        return .world(name: "loaf credentials")
    }()
    static let media = #"""
        (() => {

          if (globalThis.loafMediaControl) return;
          const frame = [...crypto.getRandomValues(new Uint32Array(4))].map(v => v.toString(16)).join('-');
          const elements = new Map();
          const presented = new Map();
          const identities = new WeakMap();
          let next = 0;
          let scheduled = false;
          const send = () => {
            scheduled = false;
            const sources = [];
            const metadata = navigator.mediaSession?.metadata;
            const candidates = [...elements].sort((a, b) => Number(a[1].paused) - Number(b[1].paused));
            const resources = new Set();
            for (const [id, el] of candidates) {
              if (!el.isConnected) { elements.delete(id); presented.delete(id); continue; }
              const tracksKnown = el.audioTracks && typeof el.audioTracks.length === 'number' && el.readyState >= 1;
              const silent = el.tagName === 'VIDEO' && (el.muted && el.loop ||
                (tracksKnown ? el.audioTracks.length === 0 :
                typeof el.webkitAudioDecodedByteCount === 'number' && el.currentTime > 2 && el.webkitAudioDecodedByteCount === 0));
              if (silent) continue;
              if (!el.currentSrc || (el.paused && !el.currentTime && presented.get(id) !== el.currentSrc)) continue;
              presented.set(id, el.currentSrc);


              const resource = metadata?.title ? 'media-session' : el.currentSrc;
              if (resources.has(resource)) continue;
              resources.add(resource);
              sources.push({ id, title: (metadata?.title || el.getAttribute('aria-label') || document.title || 'Media').slice(0, 200),
                artist: (metadata?.artist || location.hostname).slice(0, 120), paused: el.paused, muted: el.muted,
                pip: el.webkitPresentationMode === 'picture-in-picture', airplay: typeof el.webkitShowPlaybackTargetPicker === 'function', volume: el.volume, position: el.currentTime, duration: Number.isFinite(el.duration) ? el.duration : 0 });
              if (sources.length === 12) break;
            }


            window.webkit.messageHandlers.loafMedia.postMessage({ frame, sources });
          };
          const schedule = () => { if (!scheduled) { scheduled = true; setTimeout(send, 150); } };
          const mediaNodes = root => {
            if (!root.querySelectorAll) return [];
            const children = [...root.querySelectorAll('audio,video')];
            if (root.matches?.('audio,video')) children.unshift(root);
            return children;
          };
          const discover = root => {
            let changed = false;
            for (const el of mediaNodes(root)) {
              let id = identities.get(el);
              if (!id) {
                id = String(++next); identities.set(el, id);
                for (const event of ['play','pause','ended','volumechange','loadedmetadata','emptied']) el.addEventListener(event, schedule);
              }
              if (elements.get(id) === el) continue;
              elements.set(id, el); changed = true;
            }
            return changed;
          };
          discover(document);
          const observer = new MutationObserver(records => {
            let changed = false;
            for (const record of records) {
              for (const node of record.addedNodes) changed = discover(node) || changed;
              for (const node of record.removedNodes) {
                for (const el of mediaNodes(node)) {
                  const id = identities.get(el);
                  if (id && !el.isConnected && elements.delete(id)) { presented.delete(id); changed = true; }
                }
              }
            }
            if (changed) schedule();
          });
          observer.observe(document.documentElement, { childList: true, subtree: true });
          setInterval(send, 2000);
          document.addEventListener('pointerlockchange', event => {
            if (event.isTrusted) window.webkit.messageHandlers.loafMedia.postMessage({pointer:!!document.pointerLockElement});
          });
          globalThis.loafMediaControl = (id, action, value) => {
            const el = elements.get(id); if (!el || !el.isConnected) return;
            if (action === 'toggle') { if (el.paused) el.play().catch(() => {}); else el.pause(); }
            if (action === 'seek' && Number.isFinite(el.duration)) el.currentTime = Math.max(0, Math.min(el.duration, value));
            if (action === 'skip' && Number.isFinite(el.duration)) el.currentTime = Math.max(0, Math.min(el.duration, el.currentTime + value));
            if (action === 'volume' && Number.isFinite(value)) { el.volume = Math.max(0, Math.min(1, value)); el.muted = false; }
            if (action === 'airplay' && typeof el.webkitShowPlaybackTargetPicker === 'function') el.webkitShowPlaybackTargetPicker();
            if (action === 'mute') el.muted = !el.muted;
            if (action === 'pip' && el.tagName === 'VIDEO' && typeof el.webkitSetPresentationMode === 'function' && el.webkitSupportsPresentationMode?.('picture-in-picture'))
              el.webkitSetPresentationMode(el.webkitPresentationMode === 'picture-in-picture' ? 'inline' : 'picture-in-picture');
            send();
          };
        })();
        """#

    static let passwordFormHelpers = #"""
        const loafForms = globalThis.__loafCredentials || (globalThis.__loafCredentials = (() => {
          const targets = new Map();
          const tokens = field => (field.getAttribute('autocomplete') || '').toLowerCase().split(/\s+/);
          const parent = element => element.parentElement || element.getRootNode()?.host || null;
          const shadowRoots = new Set();
          const discover = root => {
            if (root instanceof ShadowRoot) shadowRoots.add(root);
            if (root.shadowRoot && !shadowRoots.has(root.shadowRoot)) discover(root.shadowRoot);
            for (const element of root.querySelectorAll('*')) if (element.shadowRoot && !shadowRoots.has(element.shadowRoot)) discover(element.shadowRoot);
          };
          discover(document);
          const active = () => {
            let el = document.activeElement;
            while (el?.shadowRoot?.activeElement) {
              if (!shadowRoots.has(el.shadowRoot)) discover(el.shadowRoot);
              el = el.shadowRoot.activeElement;
            }
            return el;
          };
          const contains = (root, element) => {
            if (root === document) return element.isConnected;
            for (let el = element; el; el = parent(el)) if (el === root || el.getRootNode() === root) return true;
            return false;
          };
          const all = (root, selector) => {
            active();
            const found = [...root.querySelectorAll(selector)];
            if (root instanceof HTMLFormElement) for (const field of root.elements) if (field.matches(selector) && !found.includes(field)) found.push(field);

            for (const shadow of shadowRoots) {
              if (!shadow.host.isConnected) { shadowRoots.delete(shadow); continue; }
              if (shadow !== root && contains(root, shadow.host)) found.push(...shadow.querySelectorAll(selector));
            }
            return found;
          };
          const visible = field => {
            if (!field?.isConnected || field.disabled || field.readOnly || field.type === 'hidden' || field.closest('[inert]')) return false;
            if (!field.getClientRects().length || field.getBoundingClientRect().width < 2 || field.getBoundingClientRect().height < 2) return false;
            for (let el = field; el; el = parent(el)) {
              const style = getComputedStyle(el);
              if (el.hidden || el.inert || style.display === 'none' || ['hidden','collapse'].includes(style.visibility) || Number(style.opacity) === 0) return false;
            }
            return typeof field.checkVisibility !== 'function' || field.checkVisibility({checkOpacity:true, checkVisibilityCSS:true});
          };
          const fieldText = field => [field.name, field.id, field.getAttribute('aria-label'), field.placeholder,
            ...[...(field.labels || [])].map(label => label.textContent)].filter(Boolean).join(' ').toLowerCase();
          const otp = field => tokens(field).includes('one-time-code') || /\b(otp|totp|verification|security.?code|one.?time|coupon|promo|search|query)\b/i.test(fieldText(field));
          const verification = field => tokens(field).includes('one-time-code') || /\b(otp|totp|verification|security.?code|one.?time)\b/i.test(fieldText(field));
          const textInputs = scope => all(scope, 'input').filter(field => ['text','email','tel'].includes(field.type) && visible(field) && !otp(field));
          const username = (scope, explicitOnly = false) => {
            const fields = textInputs(scope);
            const explicit = fields.filter(field => tokens(field).includes('username'));
            if (explicit.length) return explicit.length === 1 ? explicit[0] : null;
            const named = fields.filter(field => /user|login|e.?mail|identifier|account/i.test(fieldText(field)));
            if (named.length) return named.length === 1 ? named[0] : null;
            const emails = fields.filter(field => field.type === 'email');
            if (emails.length) return emails.length === 1 ? emails[0] : null;
            return !explicitOnly && fields.length === 1 ? fields[0] : null;
          };
          const buttons = scope => all(scope, 'button,input[type="submit"],input[type="image"],[role="button"]').filter(visible);
          const buttonText = button => (button.innerText || button.value || button.getAttribute('aria-label') || '').trim();
          const loginAction = text => /^(sign[ -]?in|log[ -]?in|continue|next|submit|entrar|connexion|anmelden)(\b|$)/i.test(text);
          const unsafeAction = text => /^(sign[ -]?up|register|reset|change\s+password|create\s+(an?\s+)?account|join|subscribe|send\s+(a\s+)?(code|link)|forgot)(\b|$)/i.test(text);
          const scopeFor = field => {
            if (field.form) return field.form;
            for (let el = parent(field); el && el !== document.body; el = parent(el)) if (el.getAttribute('role') === 'form') return el;


            for (let el = parent(field); el && el !== document.body; el = parent(el)) {
              if (all(el, 'input').filter(visible).length && buttons(el).some(button => loginAction(buttonText(button)))) return el;
            }
            return field.getRootNode() instanceof ShadowRoot ? field.getRootNode() : document;
          };
          const sameDestination = value => {
            try { const url = new URL(value || location.href, location.href); return url.origin === location.origin && ['https:','http:'].includes(url.protocol); } catch { return false; }
          };
          const safe = scope => {
            if (all(scope, 'input[type="password"]').some(field => tokens(field).includes('new-password') || /new.?password|confirm.?password|repeat.?password/i.test(fieldText(field)))) return false;
            if (scope instanceof HTMLFormElement && !sameDestination(scope.action)) return false;
            const actions = buttons(scope);
            if (actions.some(button => button.hasAttribute('formaction') && !sameDestination(button.formAction))) return false;
            const submits = actions.filter(button => button.type === 'submit' || button.type === 'image');
            const names = (submits.length ? submits : actions).map(buttonText);
            if (!submits.length && !all(scope, 'input[type="password"]').some(visible) && names.some(loginAction)) return true;
            return !names.some(unsafeAction);
          };
          const passwordCandidate = field => {
            const scope = scopeFor(field), passwords = all(scope, 'input[type="password"]').filter(visible);
            if (!safe(scope) || passwords.length !== 1 || otp(field)) return null;
            const user = username(scope);
            if (!user && textInputs(scope).length) return null;
            if (all(scope, 'input').some(input => visible(input) && verification(input))) return null;
            return {scope, password:field, user};
          };
          const choose = candidates => {
            const focused = active();
            const matching = candidates.filter(fields => fields.user === focused || fields.password === focused);
            if (matching.length === 1) return matching[0];
            return candidates.length === 1 ? candidates[0] : null;
          };
          const loginFields = () => {
            const focused = active();
            if (focused?.tagName === 'INPUT') {
              if (focused.type === 'password') return visible(focused) ? passwordCandidate(focused) : null;
              if (!['text','email','tel'].includes(focused.type) || !visible(focused) || otp(focused)) return null;
              const scope = scopeFor(focused);
              return choose(all(scope, 'input[type="password"]').filter(visible).map(passwordCandidate).filter(Boolean));
            }
            return choose(all(document, 'input[type="password"]').filter(visible).map(passwordCandidate).filter(Boolean));
          };
          const usernameFields = () => {
            const focused = active();
            if (focused?.tagName === 'INPUT' && (!['text','email','tel'].includes(focused.type) || !visible(focused) || otp(focused))) return null;


            const scopes = focused?.tagName === 'INPUT' ? [scopeFor(focused)] : [...new Set(all(document, 'input').filter(visible).map(scopeFor))];
            if (all(document, 'input[type="password"]').some(visible)) return null;
            return choose(scopes.map(scope => {
              if (!safe(scope) || !buttons(scope).some(button => loginAction(buttonText(button)))) return null;
              const user = username(scope, true);
              return user ? {scope,user,password:null} : null;
            }).filter(Boolean));
          };
          const fields = () => loginFields() || usernameFields();
          const focused = (allowPasswordOnly = false) => {
            const value = fields();
            return !!value && [value.user,value.password].includes(active()) && (!!value.user || allowPasswordOnly);
          };
          const signature = value => JSON.stringify([value.user?.type, value.user?.name, value.user?.id, value.user?.autocomplete,
            value.password?.type, value.password?.name, value.password?.id, value.password?.autocomplete,
            value.scope instanceof HTMLFormElement ? value.scope.action : '', buttons(value.scope).map(button => button.getAttribute('formaction'))]);
          const bind = () => {
            const value = fields(); if (!value) return null;
            for (const [key, saved] of targets) if (Date.now() - saved.created > 120000 || !saved.password?.isConnected && !saved.user?.isConnected) targets.delete(key);
            const key = [...crypto.getRandomValues(new Uint32Array(4))].map(n => n.toString(16).padStart(8,'0')).join('');
            if (targets.size >= 8) targets.delete(targets.keys().next().value);
            targets.set(key, {...value, signature:signature(value), created:Date.now(), href:location.href});
            return key;
          };
          const bound = key => {
            const saved = targets.get(key);
            if (!saved || Date.now() - saved.created > 120000 || saved.href !== location.href || !safe(saved.scope) || signature(saved) !== saved.signature) return null;
            if (saved.user && (!visible(saved.user) || scopeFor(saved.user) !== saved.scope)) return null;
            if (saved.password && (!visible(saved.password) || scopeFor(saved.password) !== saved.scope)) return null;
            const current = saved.password ? passwordCandidate(saved.password) : usernameFields();
            return current?.scope === saved.scope && current.user === saved.user && current.password === saved.password ? saved : null;
          };


          const anchor = (key, value = bound(key)) => {
            const field = active();
            if (!value || ![value.user,value.password].includes(field)) return null;
            const rect = field.getBoundingClientRect(), viewport = window.visualViewport;
            const offsetX = viewport?.offsetLeft || 0, offsetY = viewport?.offsetTop || 0;
            const width = viewport?.width || innerWidth, height = viewport?.height || innerHeight;
            let left = Math.max(rect.left, offsetX), top = Math.max(rect.top, offsetY);
            let right = Math.min(rect.right, offsetX + width), bottom = Math.min(rect.bottom, offsetY + height);
            for (let el = parent(field); el; el = parent(el)) {
              const style = getComputedStyle(el), clip = el.getBoundingClientRect();
              if (/(auto|scroll|hidden|clip)/.test(style.overflowX)) { left = Math.max(left,clip.left + el.clientLeft); right = Math.min(right,clip.left + el.clientLeft + el.clientWidth); }
              if (/(auto|scroll|hidden|clip)/.test(style.overflowY)) { top = Math.max(top,clip.top + el.clientTop); bottom = Math.min(bottom,clip.top + el.clientTop + el.clientHeight); }
            }
            if (right - left < Math.min(16,rect.width) || bottom - top < Math.min(8,rect.height)) return null;
            const x = (left + right)/2, y = (top + bottom)/2;
            let hit = document.elementFromPoint(x,y);
            while (hit?.shadowRoot?.elementFromPoint) {
              const next = hit.shadowRoot.elementFromPoint(x,y); if (!next || next === hit) break; hit = next;
            }
            if (hit !== field) return null;
            return {x:rect.left-offsetX, y:rect.top-offsetY, width:rect.width, height:rect.height,
              viewportWidth:width, viewportHeight:height};
          };
          const query = key => {
            const value = targets.get(key);
            return value && active() === value.user ? value.user.value.slice(0,256) : '';
          };
          const attempt = target => {
            const value = loginFields();
            if (!value || !value.password.value || value.password.value.length > 4096 || target && !all(value.scope,'*').includes(target) && value.scope !== target) return null;
            return {username:value.user?.value.slice(0,256) || '', password:value.password.value};
          };
          const usernameStep = target => {
            const value = usernameFields();
            if (!value || value.scope !== target && !all(value.scope,'*').includes(target)) return null;
            return value.user.value && value.user.value.length <= 256 ? value.user.value : null;
          };
          const fill = (origin, user, password, allowPasswordOnly, targetID) => {
            if (location.origin !== origin) return false;
            const value = targetID ? bound(targetID) : null;
            if (targetID) targets.delete(targetID);
            if (!value || !value.user && !allowPasswordOnly || !safe(value.scope)) return false;


            const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;
            if (value.user) setter.call(value.user,user);
            if (value.password) setter.call(value.password,password);
            for (const field of [value.user,value.password].filter(Boolean)) {
              if ('autofilled' in field) field.autofilled = true;
              if (!field.isConnected || !visible(field) || !safe(value.scope) || location.origin !== origin) return false;
              for (const type of ['input','change']) field.dispatchEvent(new Event(type,{bubbles:true,composed:true}));
            }
            return !!(value.user || value.password);
          };
          return {all, discover, shadowRoots, active, visible, safe, username, loginFields, usernameFields, fields, focused, bind, bound, anchor, query, attempt, usernameStep, fill, scopeFor, buttonText, loginAction};
        })());
        const editableLoginField = loafForms.visible;
        const safeLoginScope = loafForms.safe;
        const loginUsername = loafForms.username;
        const loginFields = loafForms.loginFields;
        const usernameFields = loafForms.usernameFields;
        const focusedLoginForm = loafForms.focused;
        const loginAttempt = () => loafForms.attempt();
        const usernameStep = loafForms.usernameStep;
        """#

    static let passwordCapture =
        passwordFormHelpers + #"""
            (() => {
              if (globalThis.__loafPasswordCapture) return;
              globalThis.__loafPasswordCapture = true;
              const post = body => window.webkit.messageHandlers.loafPassword.postMessage(body);
              const attempt = target => {
                const value = loafForms.attempt(target);
                if (value) post(value);
                else { const username = usernameStep(target); if (username) post({action:'remember-username',username}); }
              };
              let offeredField, offeredScope, offeredStage, timer;
              let tracking = null, frame = 0, expiry = 0, selected = false, presented = false, lastPosition = '', settlingUntil = 0;
              const resize = new ResizeObserver(() => schedulePosition());
              const position = () => {
                if (!tracking) return;
                const value = loafForms.bound(tracking);
                if (!value || ![value.user,value.password].includes(loafForms.active())) {
                  const targetID = tracking; deactivate(targetID); post({action:'dismiss-fill',targetID}); return;
                }
                const body = {action:'position-fill',targetID:tracking,anchor:loafForms.anchor(tracking,value),query:loafForms.query(tracking)};
                const serialized = JSON.stringify(body);
                if (serialized !== lastPosition) { lastPosition = serialized; post(body); }
              };
              const schedulePosition = (settle = false) => {
                if (!tracking) return;
                if (settle) settlingUntil = performance.now() + 240;
                if (frame) return;
                const tick = () => {
                  frame = 0; position();
                  if (tracking && performance.now() < settlingUntil) frame = requestAnimationFrame(tick);
                };
                frame = requestAnimationFrame(tick);
              };
              const deactivate = targetID => {
                if (targetID !== tracking) return;
                tracking = null; selected = false; presented = false; resize.disconnect();
                clearTimeout(expiry); expiry = 0;
                cancelAnimationFrame(frame); frame = 0; settlingUntil = 0;
              };
              const activate = targetID => {
                const value = loafForms.bound(targetID); if (!value) return;
                if (tracking) deactivate(tracking);
                tracking = targetID; lastPosition = ''; selected = false;
                expiry = setTimeout(() => { deactivate(targetID); post({action:'dismiss-fill',targetID}); },Math.max(0,120000 - (Date.now() - value.created)));


                for (let el = loafForms.active(); el; el = el.parentElement || el.getRootNode()?.host) resize.observe(el);
                position();
              };
              globalThis.__loafPasswordSuggestions = {activate,deactivate,visibility:(targetID,value) => { if (tracking === targetID) { presented = value; if (!value) selected = false; } },selection:(targetID,value) => {if (tracking === targetID) selected = value;}};
              const offer = (userInitiated = false) => {
                if (location.protocol !== 'https:' || !focusedLoginForm(true)) { schedulePosition(); return; }
                const fields = loafForms.fields(), field = loafForms.active();
                const stage = fields.password ? (fields.user ? 'login' : 'password') : 'username';
                if (!userInitiated && offeredField === field && offeredScope === fields.scope && offeredStage === stage) { schedulePosition(); return; }
                const targetID = loafForms.bind(); if (!targetID) return;
                const anchor = loafForms.anchor(targetID); if (!anchor) return;
                if (tracking) deactivate(tracking);
                offeredField = field; offeredScope = fields.scope; offeredStage = stage;
                post({action:'offer-fill',passwordOnly:!fields.user,stage,userInitiated,targetID,anchor,query:loafForms.query(targetID)});
              };
              const schedule = () => {
                schedulePosition(true);
                if (!timer && loafForms.active()?.tagName === 'INPUT') timer = setTimeout(() => { timer = null; offer(); },100);
              };
              document.addEventListener('scroll',() => schedulePosition(),true);
              window.addEventListener('resize',() => schedulePosition(true));
              window.visualViewport?.addEventListener('resize',() => schedulePosition(true));
              window.visualViewport?.addEventListener('scroll',() => schedulePosition());
              document.addEventListener('input',() => { selected = false; schedulePosition(); },true);
              document.addEventListener('focusout',() => schedulePosition(),true);

              const motion = event => {
                if (!tracking) return;
                const field = loafForms.active();
                if (event.composedPath().includes(field) || event.target?.contains?.(field) || field?.getRootNode()?.host && event.target?.contains?.(field.getRootNode().host)) {
                  const style = getComputedStyle(event.target);
                  const duration = text => Math.max(0,...text.split(',').map(value => parseFloat(value) * (value.trim().endsWith('ms') ? 1 : 1000)));
                  settlingUntil = performance.now() + Math.min(5000,Math.max(duration(style.transitionDuration)+duration(style.transitionDelay),duration(style.animationDuration)+duration(style.animationDelay),240));
                  schedulePosition();
                }
              };
              document.addEventListener('transitionrun',motion,true);
              document.addEventListener('animationstart',motion,true);
              for (const event of ['transitionend','transitioncancel','animationend','animationcancel']) document.addEventListener(event,() => schedulePosition(),true);
              document.addEventListener('pointerdown',event => {
                if (!event.isTrusted || !tracking) return;
                const target = event.composedPath()[0];
                if (target !== loafForms.active() && target.closest?.('label')?.control !== loafForms.active()) {
                  const targetID = tracking; deactivate(targetID); post({action:'dismiss-fill',targetID});
                }
              },true);
              const observer = new MutationObserver(records => {
                for (const record of records) for (const node of record.addedNodes) if (node.nodeType === 1) loafForms.discover(node);
                observeRoots(); schedule();
              });
              const observed = new WeakSet();
              const observeRoots = () => {
                for (const root of [document.documentElement, ...loafForms.shadowRoots]) {
                  if (!observed.has(root)) { observed.add(root); observer.observe(root,{childList:true,subtree:true,attributes:true,attributeFilter:['type','name','id','form','role','autocomplete','aria-label','placeholder','disabled','readonly','hidden','style','class','action','formaction']}); }
                }
              };
              observeRoots();
              document.addEventListener('focusin',event => { if (event.isTrusted) { offer(); observeRoots(); } },true);
              document.addEventListener('submit',event => { if (event.isTrusted && location.protocol === 'https:') attempt(event.target); },true);
              document.addEventListener('keydown',event => {
                if (!event.isTrusted) return;
                if (tracking && presented && !event.isComposing && (['ArrowDown','ArrowUp','Escape'].includes(event.key) || event.key === 'Enter' && selected)) {
                  event.preventDefault(); event.stopImmediatePropagation();
                  if (event.key === 'ArrowDown' || event.key === 'ArrowUp') selected = true;
                  post({action:'key-fill',targetID:tracking,key:event.key});
                  if (event.key === 'Escape' || event.key === 'Enter') deactivate(tracking);
                  return;
                }
                if (event.key === 'Tab') requestAnimationFrame(() => offer(true));
                if (location.protocol === 'https:' && event.key === 'Enter' && !event.isComposing) attempt(event.composedPath()[0]);
              },true);
              document.addEventListener('click',event => {
                if (!event.isTrusted || location.protocol !== 'https:') return;
                const target = event.composedPath()[0];
                if (target === loafForms.active() || target.closest('label')?.control === loafForms.active()) offer(true);
                const button = target.closest('button,input[type="submit"],[role="button"]');
                if (button && !button.disabled && (button.type === 'submit' || loafForms.loginAction(loafForms.buttonText(button)))) attempt(button);
              },true);
              offer();
            })();
            """#

    static let passwordPresentation =
        passwordCapture + #"""
            if (!loafForms.focused(true)) return null;
            const targetID = loafForms.bind();
            const anchor = targetID && loafForms.anchor(targetID);
            return anchor ? {targetID,anchor,query:loafForms.query(targetID)} : null;
            """#

    static let passwordTarget = passwordFormHelpers + "\nreturn loafForms.bind();"

    static let passwordFill =
        passwordFormHelpers + #"""
            return loafForms.fill(origin, username, password, typeof allowPasswordOnly !== 'undefined' && allowPasswordOnly, typeof targetID !== 'undefined' ? targetID : '');
            """#
}
