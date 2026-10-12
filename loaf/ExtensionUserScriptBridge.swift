import Foundation

enum ExtensionUserScriptBridge {
    static let host = "app.tryloaf.loaf.userscripts"
    static let script = #"""
                (() => {
                    const api = globalThis.chrome || globalThis.browser;
                    if (!api?.runtime?.sendNativeMessage || api.userScripts) return;
                    const runtime = api.runtime;
                    if (!runtime.getManifest().permissions?.includes('userScripts')) return;
                    const host = 'app.tryloaf.loaf.compatibility';
                    const invoke = (operation, args) => new Promise((resolve, reject) => {
                        runtime.sendNativeMessage(host, {operation:'userScripts.' + operation, args}, result => {
                            const error = runtime.lastError;
                            if (error) reject(new Error(error.message)); else resolve(result?.value);
                        });
                    });
                    api.userScripts = {
                        register: scripts => invoke('register', {scripts}),
                        update: scripts => invoke('update', {scripts}),
                        unregister: (filter = {}) => invoke('unregister', filter),
                        getScripts: (filter = {}) => invoke('getScripts', filter),
                        configureWorld: properties => invoke('configureWorld', properties),
                        getWorldConfigurations: () => invoke('getWorldConfigurations', {}),
                        resetWorldConfiguration: worldId => invoke('resetWorldConfiguration', {worldId})
                    };
                    const event = () => {
                        const listeners = new Set();
                        return {addListener: fn => listeners.add(fn), removeListener: fn => listeners.delete(fn),
                            hasListener: fn => listeners.has(fn), hasListeners: () => !!listeners.size,
                            dispatch: (...args) => { for (const fn of [...listeners]) fn(...args); }, listeners};
                    };
                    runtime.onUserScriptMessage = event();
                    runtime.onUserScriptConnect = event();
                    const manifest = runtime.getManifest();
                    const background = typeof document === 'undefined' ||
                        (manifest.background?.page && location.href === runtime.getURL(manifest.background.page));
                    if (!background) return;
                    const ports = new Map();
                    let native;
                    const connect = () => {
                        native = runtime.connectNative('app.tryloaf.loaf.userscripts');
                        native.onDisconnect.addListener(() => {
                            void runtime.lastError;
                            for (const port of ports.values()) port.onDisconnect.dispatch(port);
                            ports.clear();
                        });
                        const send = message => native.postMessage(message);
                        native.onMessage.addListener(async message => {
                            const {requestID, operation, sender, portID} = message;
                            const reply = (value, error) => send({requestID, value: value ?? null, error});
                            if (operation === 'resolveSender') {
                                try {


                                    const tabs = await api.tabs.query({});
                                    for (const tab of tabs) {
                                        if (!tab.id) continue;
                                        try {
                                            const results = await api.scripting.executeScript({target:{tabId:tab.id, allFrames:true},
                                                world:'MAIN', func: key => globalThis[key] === true, args:[message.marker]});
                                            const frame = results.find(result => result.result === true);
                                            if (frame) { reply({tab, frameId:frame.frameId, url:message.url, id:runtime.id}); return; }
                                        } catch (_) {}
                                    }
                                    reply(null, 'The userscript frame is no longer available.');
                                } catch (error) { reply(null, String(error)); }
                            } else if (operation === 'sendMessage') {
                                let answered = false;
                                const respond = value => { if (!answered) { answered = true; reply(value); } };
                                let pending = false;
                                for (const listener of runtime.onUserScriptMessage.listeners) {
                                    try {
                                        const result = listener(message.message, sender, respond);
                                        if (result === true) pending = true;
                                        else if (result?.then) { pending = true; result.then(respond, error => {
                                            if (!answered) { answered = true; reply(null, String(error)); }
                                        }); }
                                    } catch (error) { if (!answered) { answered = true; reply(null, String(error)); } }
                                }
                                if (!pending && !answered) reply(null);
                            } else if (operation === 'connect') {
                                const port = {name:message.name || '', sender, onMessage:event(), onDisconnect:event(),
                                    postMessage: value => send({operation:'portMessage', portID, message:value}),
                                    disconnect: () => { if (ports.delete(portID)) {
                                        send({operation:'portDisconnect', portID}); port.onDisconnect.dispatch(port);
                                    } }};
                                ports.set(portID, port);
                                runtime.onUserScriptConnect.dispatch(port);
                            } else if (operation === 'postMessage') {
                                const port = ports.get(portID);
                                if (port) port.onMessage.dispatch(message.message, port);
                            } else if (operation === 'disconnect') {
                                const port = ports.get(portID);
                                if (port) { ports.delete(portID); port.onDisconnect.dispatch(port); }
                            }
                        });
                    };
                    connect();
                })();
        """#

    static let runtime = #"""
                (() => {
                    if (globalThis.__loafUserScriptRuntime) return;
                    const config = __LOAF_CONFIG__;
                    const transport = webkit.messageHandlers[config.handler];

                    const randomID = () => Array.from(crypto.getRandomValues(new Uint8Array(16)),
                        byte => byte.toString(16).padStart(2, '0')).join('');
                    const documentID = randomID();
                    const ports = new Map();
                    const closePorts = new WeakMap();
                    const event = () => {
                        const listeners = new Set();
                        return {addListener: fn => listeners.add(fn), removeListener: fn => listeners.delete(fn),
                            hasListener: fn => listeners.has(fn), hasListeners: () => !!listeners.size,
                            dispatch: (...args) => { for (const fn of [...listeners]) fn(...args); }, listeners};
                    };
                    const request = (operation, args = {}) => transport.postMessage({operation, documentID, ...args});
                    const runtime = {id:config.id, lastError:undefined, onMessage:event(),
                        getURL: path => new URL(path, config.baseURL).href,
                        getPlatformInfo: callback => { const value = {os:'mac', arch:config.arch};
                            if (callback) callback(value); else return Promise.resolve(value); },
                        sendMessage: (...args) => {
                            const callback = typeof args.at(-1) === 'function' ? args.pop() : undefined;
                            if (args.length > 2 || (args.length > 1 && typeof args[0] === 'string' &&
                                (!args[1] || typeof args[1] !== 'object' || Object.keys(args[1]).some(key => key !== 'includeTlsChannelId'))))
                                throw new Error('External userscript messaging is unsupported.');
                            const promise = request('sendMessage', {message:args[0]});
                            if (!callback) return promise;
                            promise.then(callback, error => { runtime.lastError = {message:String(error)};
                                try { callback(); } finally { runtime.lastError = undefined; } });
                        },
                        connect: (info = {}) => {
                            if (typeof info !== 'object') throw new Error('External userscript connections are unsupported.');
                            const portID = randomID();
                            let closed = false;
                            const close = () => { if (closed) return; closed = true; ports.delete(portID); port.onDisconnect.dispatch(port); };
                            const port = {name:info.name || '', onMessage:event(), onDisconnect:event(),
                                postMessage: message => { if (closed) throw new Error('Disconnected port');
                                    ready.then(() => request('postMessage', {portID, message})).catch(fail); },
                                disconnect: () => { if (closed) return;
                                    ready.then(() => request('disconnect', {portID})).catch(() => {}); close(); }};
                            const fail = error => { if (closed) return;
                                runtime.lastError = {message:String(error)};
                                try { close(); } finally { runtime.lastError = undefined; } };
                            ports.set(portID, port);
                            closePorts.set(port, close);
                            const ready = request('connect', {portID, name:port.name});
                            ready.catch(fail);
                            return port;
                        }};
                    globalThis.chrome = globalThis.browser = {runtime, extension:{inIncognitoContext:false}};
                    globalThis.__loafUserScriptRuntime = {
                        receive: (operation, portID, message) => {
                            const port = ports.get(portID);
                            if (!port) return;
                            if (operation === 'portMessage') port.onMessage.dispatch(message, port);
                            else closePorts.get(port)();
                        }};
                    addEventListener('pagehide', () => {
                        for (const port of [...ports.values()]) port.disconnect();
                        request('closeDocument').catch(() => {});
                    }, {once:true});
                })();
        """#
}
