import Foundation

nonisolated enum AudioRecovery {


    static let script = #"""
        (() => {
          const installed = Symbol.for('loaf.audioRecovery');
          if (globalThis[installed] || typeof WeakRef !== 'function') return;
          Object.defineProperty(globalThis, installed, {value: true});
          const states = new WeakMap();
          const contexts = new Set();
          const constructors = new Map();
          const prototypes = new WeakMap();
          const track = (context, methods) => {
            if (states.has(context)) return;
            const reference = new WeakRef(context);
            const state = {reference, methods, played: context.state === 'running', paused: false,
              checking: false, retryAfter: 0, lastInteraction: -Infinity};
            states.set(context, state);
            contexts.add(reference);
            context.addEventListener('statechange', () => {
              if (context.state === 'running') state.played = true;
              if (context.state === 'closed') contexts.delete(reference);
            });
          };
          for (const name of ['AudioContext', 'webkitAudioContext']) {
            const Native = globalThis[name];
            if (typeof Native !== 'function') continue;
            let Wrapped = constructors.get(Native);
            if (!Wrapped) {
              const prototype = Native.prototype;
              let methods = prototypes.get(prototype);
              if (!methods) {
                methods = {suspend: prototype.suspend, resume: prototype.resume};
                prototypes.set(prototype, methods);
                for (const method of ['suspend', 'resume']) {
                  const descriptor = Object.getOwnPropertyDescriptor(prototype, method);
                  if (!descriptor || typeof descriptor.value !== 'function') continue;
                  Object.defineProperty(prototype, method, {...descriptor, value: new Proxy(descriptor.value, {
                    apply(target, context, args) {
                      const state = states.get(context);
                      if (state) {
                        state.paused = method === 'suspend';
                      }
                      return Reflect.apply(target, context, args);
                    }
                  })});
                }
              }
              Wrapped = new Proxy(Native, {
                construct(target, args, newTarget) {
                  const context = Reflect.construct(target, args, newTarget);
                  track(context, methods);
                  return context;
                }
              });
              const descriptor = Object.getOwnPropertyDescriptor(prototype, 'constructor');
              if (descriptor?.configurable) Object.defineProperty(prototype, 'constructor', {...descriptor, value: Wrapped});
              constructors.set(Native, Wrapped);
            }
            globalThis[name] = Wrapped;
          }
          const activePage = () => !document.hidden && document.hasFocus();
          const recover = event => {
            if (!event.isTrusted || event.repeat || !activePage()) return;
            for (const reference of contexts) {
              const context = reference.deref();
              if (!context || context.state === 'closed') { contexts.delete(reference); continue; }
              const state = states.get(context);
              const now = performance.now();
              const idle = now - state.lastInteraction >= 1000;
              state.lastInteraction = now;
              if (!state.played || state.paused || now < state.retryAfter) continue;
              if (context.state === 'interrupted' || context.state === 'suspended') {
                state.retryAfter = performance.now() + 1000;
                Reflect.apply(state.methods.resume, context, []).catch(() => {});
              } else if (context.state === 'running' && idle && !state.checking) {

                const time = context.currentTime;
                state.checking = true;
                setTimeout(() => {
                  state.checking = false;
                  if (!activePage() || state.paused || context.state !== 'running' || context.currentTime > time
                      || performance.now() < state.retryAfter) return;
                  state.retryAfter = performance.now() + 1000;
                  Reflect.apply(state.methods.suspend, context, []).then(() => {
                    if (!state.paused && activePage() && context.state !== 'closed')
                      return Reflect.apply(state.methods.resume, context, []);
                  }).catch(() => {});
                }, 200);
              }
            }
          };
          document.addEventListener('pointerdown', recover, {capture: true, passive: true});
          document.addEventListener('keydown', recover, {capture: true, passive: true});
        })();
        """#
}
