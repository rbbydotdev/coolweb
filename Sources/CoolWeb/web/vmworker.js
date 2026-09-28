// VMWorker: a Worker whose script runs in a Linux VM. Injected at document start by the CoolWeb host.
//
//   const vm = new VMWorker("worker.py", { cpus: 2, memory: "512MB", network: true });
//   vm.onmessage = (e) => e.data;   vm.postMessage(value, [transferables]);   vm.terminate();
//   worker.postMessage({ vm: vm.connect() }, [port])  // hand the VM to a Web Worker
//
// Files: each origin has persistent VM storage, reached as a directory handle (see vmfs.js):
//   const root = await VMWorker.getDirectory();                  // FileSystemDirectoryHandle shape
//   new VMWorker("build.sh")                                     // root is mounted at /work by default
//   new VMWorker("x.sh", { mounts: { "/data": subdirHandle } })  // or mount chosen handles; {} for none
//
// Inside the VM the script's stdin/stdout are the message port. stderr shows in this page's console.
// The VM powers off when the script exits. $VMWORKER_SERIALIZATION tells the script the wire format:
//
//   "advanced" (default)  Structured clone. Each message is a frame: u32 big-endian length, then one
//                         CBOR item (RFC 8949). Type mapping:
//                           ArrayBuffer            byte string
//                           typed arrays           RFC 8746 tags 64-87 (little-endian)
//                           Map / Set              tag 259 map / tag 258 array
//                           Date                   tag 1 (epoch seconds)
//                           BigInt                 tag 2 / 3
//                           RegExp                 tag 21066 [source, flags]
//                           DataView, Error        tag 27 ["DataView", bytes] / ["Error", {name, message, stack, cause}]
//                           shared refs, cycles    tag 28 (shareable) / tag 29 (reference)
//                           undefined, NaN, -0     CBOR undefined / float64
//   "json"                One JSON value per line. Plain objects, arrays, strings, numbers, booleans, null.
(() => {
  const handler = globalThis.webkit?.messageHandlers?.vmworker;
  if (!handler || "VMWorker" in globalThis) return;

  const DISPATCH = Symbol("dispatch");
  const workers = new Map();

  const call = (op, args) => {
    const msg = { op };
    for (const [k, v] of Object.entries(args)) if (v !== undefined) msg[k] = v;
    return handler.postMessage(msg);
  };

  const cloneError = (what) => new DOMException(`${what} could not be cloned.`, "DataCloneError");

  // MARK: base64 (the native bridge carries strings only)

  const toBase64 = Uint8Array.prototype.toBase64
    ? (u8) => u8.toBase64()
    : (u8) => {
        let s = "";
        for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000));
        return btoa(s);
      };
  const fromBase64 = Uint8Array.fromBase64
    ? (s) => Uint8Array.fromBase64(s)
    : (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));

  // MARK: CBOR structured clone

  const TYPED = [
    // [tag, constructor name, bytes per element, little-endian]
    [64, "Uint8Array", 1, true], [68, "Uint8ClampedArray", 1, true], [72, "Int8Array", 1, true],
    [65, "Uint16Array", 2, false], [66, "Uint32Array", 4, false], [67, "BigUint64Array", 8, false],
    [69, "Uint16Array", 2, true], [70, "Uint32Array", 4, true], [71, "BigUint64Array", 8, true],
    [73, "Int16Array", 2, false], [74, "Int32Array", 4, false], [75, "BigInt64Array", 8, false],
    [77, "Int16Array", 2, true], [78, "Int32Array", 4, true], [79, "BigInt64Array", 8, true],
    [80, "Float16Array", 2, false], [81, "Float32Array", 4, false], [82, "Float64Array", 8, false],
    [84, "Float16Array", 2, true], [85, "Float32Array", 4, true], [86, "Float64Array", 8, true],
  ].filter(([, name]) => typeof globalThis[name] === "function");
  const TAG_BY_TYPE = new Map(TYPED.filter(([, , , le]) => le).map(([tag, name]) => [name, tag]));
  const TYPE_BY_TAG = new Map(TYPED.map(([tag, name, size, le]) => [tag, { ctor: globalThis[name], size, le }]));
  const ERRORS = { Error, EvalError, RangeError, ReferenceError, SyntaxError, TypeError, URIError };

  const utf8 = new TextEncoder();
  const fromUtf8 = new TextDecoder("utf-8", { fatal: true });
  const kind = (v) => Object.prototype.toString.call(v).slice(8, -1);

  function encode(root) {
    // Pass 1: objects reached more than once become shareable (tag 28); covers cycles too.
    const seen = new Map();
    (function walk(v) {
      if (v === null || typeof v !== "object") return;
      if (seen.has(v)) return void seen.set(v, seen.get(v) + 1);
      seen.set(v, 1);
      const k = kind(v);
      if (k === "Array") v.forEach(walk);
      else if (k === "Map") v.forEach((val, key) => { walk(key); walk(val); });
      else if (k === "Set") v.forEach(walk);
      else if (k === "Object" || k === "Error") for (const key of Object.keys(v)) walk(v[key]);
    })(root);
    const shareIndex = new Map();

    let buf = new Uint8Array(256), view = new DataView(buf.buffer), len = 0;
    const ensure = (n) => {
      if (len + n <= buf.length) return;
      let cap = buf.length * 2;
      while (cap < len + n) cap *= 2;
      const next = new Uint8Array(cap);
      next.set(buf.subarray(0, len));
      buf = next;
      view = new DataView(buf.buffer);
    };
    const byte = (b) => { ensure(1); buf[len++] = b; };
    const head = (major, n) => {
      const m = major << 5;
      if (typeof n === "bigint") { ensure(9); buf[len++] = m | 27; view.setBigUint64(len, n); len += 8; }
      else if (n < 24) byte(m | n);
      else if (n < 0x100) { ensure(2); buf[len++] = m | 24; buf[len++] = n; }
      else if (n < 0x10000) { ensure(3); buf[len++] = m | 25; view.setUint16(len, n); len += 2; }
      else if (n < 0x100000000) { ensure(5); buf[len++] = m | 26; view.setUint32(len, n); len += 4; }
      else { ensure(9); buf[len++] = m | 27; view.setBigUint64(len, BigInt(n)); len += 8; }
    };
    const bytes = (u8) => { head(2, u8.length); ensure(u8.length); buf.set(u8, len); len += u8.length; };
    const text = (s) => { const b = utf8.encode(s); head(3, b.length); ensure(b.length); buf.set(b, len); len += b.length; };
    const float = (x) => { ensure(9); buf[len++] = 0xfb; view.setFloat64(len, x); len += 8; };
    const copyBytes = (buffer, offset, length) => new Uint8Array(buffer, offset, length).slice();

    function item(v) {
      switch (typeof v) {
        case "undefined": return byte(0xf7);
        case "boolean": return byte(v ? 0xf5 : 0xf4);
        case "string": return text(v);
        case "number":
          if (Number.isSafeInteger(v) && !Object.is(v, -0)) return v >= 0 ? head(0, v) : head(1, -1 - v);
          return float(v);
        case "bigint": {
          const neg = v < 0n;
          let mag = neg ? -1n - v : v;
          const out = [];
          do { out.unshift(Number(mag & 0xffn)); mag >>= 8n; } while (mag > 0n);
          head(6, neg ? 3 : 2);
          return bytes(Uint8Array.from(out));
        }
        case "object": break;
        default: throw cloneError(typeof v === "function" ? "A function" : `A ${typeof v}`);
      }
      if (v === null) return byte(0xf6);

      if (seen.get(v) > 1) {
        if (shareIndex.has(v)) { head(6, 29); return head(0, shareIndex.get(v)); }
        shareIndex.set(v, shareIndex.size);
        head(6, 28);
      }

      const k = kind(v);
      if (ArrayBuffer.isView(v) && k !== "DataView") {
        const tag = TAG_BY_TYPE.get(k);
        if (tag === undefined) throw cloneError(k);
        if (kind(v.buffer) === "SharedArrayBuffer") throw cloneError("A view on a SharedArrayBuffer");
        head(6, tag);
        return bytes(copyBytes(v.buffer, v.byteOffset, v.byteLength));
      }
      switch (k) {
        case "Array":
          head(4, v.length);
          for (let i = 0; i < v.length; i++) item(v[i]);
          return;
        case "Object": {
          const keys = Object.keys(v);
          head(5, keys.length);
          for (const key of keys) { text(key); item(v[key]); }
          return;
        }
        case "ArrayBuffer":
          if (v.detached) throw cloneError("A detached ArrayBuffer");
          return bytes(new Uint8Array(v));
        case "SharedArrayBuffer":
          throw cloneError("A SharedArrayBuffer (VMWorker cannot share memory yet)");
        case "DataView":
          head(6, 27); head(4, 2); text("DataView");
          return bytes(copyBytes(v.buffer, v.byteOffset, v.byteLength));
        case "Map":
          head(6, 259); head(5, v.size);
          v.forEach((val, key) => { item(key); item(val); });
          return;
        case "Set":
          head(6, 258); head(4, v.size);
          v.forEach(item);
          return;
        case "Date": {
          const t = v.getTime();
          head(6, 1);
          return Number.isSafeInteger(t) && t % 1000 === 0 ? item(t / 1000) : float(t / 1000);
        }
        case "RegExp":
          head(6, 21066); head(4, 2); text(v.source);
          return text(v.flags);
        case "Error": {
          const e = { name: String(v.name), message: String(v.message) };
          if (typeof v.stack === "string") e.stack = v.stack;
          if ("cause" in v) e.cause = v.cause;
          head(6, 27); head(4, 2); text("Error");
          return item(e);
        }
        case "Boolean": case "Number": case "String": case "BigInt":
          return item(v.valueOf());
        default:
          throw cloneError(`A ${k}`);
      }
    }

    item(root);
    return buf.subarray(0, len);
  }

  function decode(u8) {
    const view = new DataView(u8.buffer, u8.byteOffset, u8.byteLength);
    const refs = [];
    let pos = 0;

    const need = (n) => { if (pos + n > u8.length) throw new Error("CBOR message ends early."); };
    const length = (ai) => {
      if (ai < 24) return ai;
      if (ai === 24) { need(1); return u8[pos++]; }
      if (ai === 25) { need(2); const n = view.getUint16(pos); pos += 2; return n; }
      if (ai === 26) { need(4); const n = view.getUint32(pos); pos += 4; return n; }
      if (ai === 27) {
        need(8);
        const n = view.getBigUint64(pos); pos += 8;
        return n <= BigInt(Number.MAX_SAFE_INTEGER) ? Number(n) : n;
      }
      if (ai === 31) return -1; // indefinite length
      throw new Error(`Invalid CBOR length encoding ${ai}.`);
    };
    const isBreak = () => u8[pos] === 0xff && ++pos;
    const byteString = (ai) => {
      const n = length(ai);
      if (n === -1) {
        const parts = [];
        while (!isBreak()) parts.push(new Uint8Array(item()));
        const out = new Uint8Array(parts.reduce((s, p) => s + p.length, 0));
        let o = 0;
        for (const p of parts) { out.set(p, o); o += p.length; }
        return out.buffer;
      }
      need(n);
      const out = u8.slice(pos, pos + n).buffer;
      pos += n;
      return out;
    };
    const register = (share, value) => { if (share !== undefined) refs[share] = value; return value; };

    // `share` is the tag-28 slot this item fills. Containers register before their children so cycles resolve.
    function item(share, as) {
      need(1);
      const ib = u8[pos++], major = ib >> 5, ai = ib & 31;
      switch (major) {
        case 0: return register(share, length(ai));
        case 1: { const n = length(ai); return register(share, typeof n === "bigint" ? -1n - n : -1 - n); }
        case 2: return register(share, byteString(ai));
        case 3: {
          if (ai === 31) { let s = ""; while (!isBreak()) s += item(); return register(share, s); }
          const n = length(ai);
          need(n);
          const s = fromUtf8.decode(u8.subarray(pos, pos + n));
          pos += n;
          return register(share, s);
        }
        case 4: {
          const n = length(ai);
          if (as === "set") {
            const set = register(share, new Set());
            if (n === -1) while (!isBreak()) set.add(item()); else for (let i = 0; i < n; i++) set.add(item());
            return set;
          }
          const arr = register(share, []);
          if (n === -1) while (!isBreak()) arr.push(item()); else for (let i = 0; i < n; i++) arr.push(item());
          return arr;
        }
        case 5: {
          const n = length(ai);
          const entries = [];
          const map = as === "map" ? register(share, new Map()) : null;
          // Plain objects need string keys; decide after reading keys, so register a placeholder object first.
          const obj = map ? null : register(share, {});
          const put = () => {
            const k = item(), v = item();
            if (map) map.set(k, v); else entries.push([k, v]);
          };
          if (n === -1) while (!isBreak()) put(); else for (let i = 0; i < n; i++) put();
          if (map) return map;
          if (entries.every(([k]) => typeof k === "string")) {
            for (const [k, v] of entries) obj[k] = v;
            return obj;
          }
          // A map with non-string keys from a non-JS sender becomes a Map.
          return register(share, new Map(entries));
        }
        case 6: {
          const tag = length(ai);
          switch (tag) {
            case 28: { const slot = refs.length; refs.push(undefined); return item(slot); }
            case 29: {
              const i = item();
              if (!(i in refs)) throw new Error(`CBOR shared reference ${i} is unknown.`);
              return register(share, refs[i]);
            }
            case 259: return item(share, "map");
            case 258: return item(share, "set");
            case 0: return register(share, new Date(item()));
            case 1: { const s = item(); return register(share, new Date(Math.round(Number(s) * 1000))); }
            case 2: case 3: {
              let n = 0n;
              for (const b of new Uint8Array(item())) n = (n << 8n) | BigInt(b);
              return register(share, tag === 2 ? n : -1n - n);
            }
            case 21066: { const [source, flags] = item(); return register(share, new RegExp(source, flags)); }
            case 27: {
              const [type, value] = item();
              if (type === "DataView") return register(share, new DataView(value));
              if (type === "Error") {
                const Ctor = ERRORS[value.name] ?? Error;
                const err = "cause" in value ? new Ctor(value.message, { cause: value.cause }) : new Ctor(value.message);
                if (!(value.name in ERRORS)) err.name = value.name;
                if (value.stack !== undefined) err.stack = value.stack;
                return register(share, err);
              }
              return register(share, value);
            }
            default: {
              const t = TYPE_BY_TAG.get(tag);
              const inner = item();
              if (!t) return register(share, inner); // unknown tag: keep the content
              if (!t.le && t.size > 1) {
                const b = new Uint8Array(inner);
                for (let i = 0; i < b.length; i += t.size) b.subarray(i, i + t.size).reverse();
              }
              return register(share, new t.ctor(inner));
            }
          }
        }
        case 7:
          switch (ai) {
            case 20: return register(share, false);
            case 21: return register(share, true);
            case 22: return register(share, null);
            case 23: return register(share, undefined);
            case 25: { need(2); const h = view.getUint16(pos); pos += 2; return register(share, half(h)); }
            case 26: { need(4); const f = view.getFloat32(pos); pos += 4; return register(share, f); }
            case 27: { need(8); const f = view.getFloat64(pos); pos += 8; return register(share, f); }
            default: if (ai < 24) return register(share, undefined);
          }
      }
      throw new Error(`Unsupported CBOR item 0x${ib.toString(16)}.`);
    }

    const value = item();
    if (pos !== u8.length) throw new Error("CBOR message has trailing bytes.");
    return value;
  }

  function half(h) {
    const exp = (h >> 10) & 0x1f, mant = h & 0x3ff, sign = h & 0x8000 ? -1 : 1;
    if (exp === 0) return sign * 2 ** -14 * (mant / 1024);
    if (exp === 31) return mant ? NaN : sign * Infinity;
    return sign * 2 ** (exp - 15) * (1 + mant / 1024);
  }

  /** postMessage(message, transfer) and postMessage(message, { transfer }), like Worker. */
  function transferList(arg) {
    const list = Array.isArray(arg) ? arg : arg?.transfer ?? [];
    for (const t of list) {
      const k = kind(t);
      if (k !== "ArrayBuffer") throw new DOMException(`A ${k} cannot be transferred to a VMWorker yet.`, "DataCloneError");
      if (t.detached) throw cloneError("A detached ArrayBuffer");
    }
    return list;
  }

  // MARK: Storage

  /** [{path, url}] for the host. Default: this origin's storage root at /work. */
  async function resolveMounts(mounts) {
    const spec = mounts ?? { "/work": await VMWorker.getDirectory() };
    return Object.entries(spec).map(([path, handle]) => {
      if (typeof path !== "string" || !path.startsWith("/") || path === "/" || /[\n\r\0]/.test(path)) {
        throw new TypeError(`Mount path must be an absolute path other than "/": ${path}.`);
      }
      if (handle?.kind !== "directory" || typeof handle.url !== "string") {
        throw new TypeError(`Mount ${path} needs a VM directory handle.`);
      }
      return { path, url: handle.url };
    });
  }

  // MARK: VMWorker

  class VMWorker extends EventTarget {
    #id = null;
    #ready;
    #terminated = false;
    #ports = new Set();
    #resolveExit;

    constructor(scriptURL, options = {}) {
      super();
      const url = new URL(scriptURL, location.href);
      const serialization = options.serialization ?? "advanced";
      if (serialization !== "advanced" && serialization !== "json") {
        throw new TypeError(`VMWorker serialization must be "advanced" or "json", not "${serialization}".`);
      }
      this.name = options.name ?? url.pathname.split("/").pop();
      this.serialization = serialization;
      this.exited = new Promise((resolve) => (this.#resolveExit = resolve));

      this.#ready = (async () => {
        const res = await fetch(url);
        if (!res.ok) throw new Error(`VMWorker script cannot load: ${url} (${res.status}).`);
        const script = await res.text();
        const mounts = await resolveMounts(options.mounts);
        const info = await call("create", {
          script, serialization, mounts, cpus: options.cpus, memory: options.memory, network: options.network,
        });
        this.#id = info.id;
        this.cpus = info.cpus;
        this.memoryMB = info.memoryMB;
        workers.set(info.id, this);
        if (this.#terminated) call("terminate", { id: info.id });
      })();
      this.#ready.catch((err) => this.#close(null, err?.message ?? String(err)));
    }

    /** Serializes now (so later mutation has no effect and errors throw here), sends when the VM is up. */
    postMessage(message, transfer) {
      if (this.#terminated) return;
      const list = transferList(transfer);
      let args;
      if (this.serialization === "json") {
        args = { data: JSON.stringify(message) ?? "null" };
      } else {
        args = { bytes: toBase64(encode(message)) };
      }
      // Transferred buffers detach in the sender, like postMessage to a Worker.
      if (list.length) structuredClone(list, { transfer: list });
      this.#ready.then(() => call("post", { id: this.#id, ...args }), () => {});
    }

    /**
     * Serves a TCP port of the VM to the browser as its own origin, http://127.0.0.1:<port>/.
     * Resolves once something in the VM listens on the port, so it doubles as a "server ready" signal.
     */
    async serve(port) {
      await this.#ready;
      return call("serve", { id: this.#id, port });
    }

    /** A MessagePort wired to this VM. Transfer it to a Web Worker, iframe, or another port holder. */
    connect() {
      const { port1, port2 } = new MessageChannel();
      port1.onmessage = (e) => {
        try { this.postMessage(e.data); } catch (err) { port1.postMessage({ error: String(err) }); }
      };
      this.#ports.add(port1);
      return port2;
    }

    terminate() {
      if (this.#terminated) return;
      this.#terminated = true;
      this.#ready.then(() => call("terminate", { id: this.#id }), () => {});
    }

    [DISPATCH](e) {
      if (e.type === "message") {
        let data;
        try {
          data = e.bytes !== undefined ? decode(fromBase64(e.bytes)) : JSON.parse(e.data);
        } catch (err) {
          console.warn(`[VMWorker ${this.name}] message cannot be decoded:`, err);
          return this.dispatchEvent(new MessageEvent("messageerror"));
        }
        this.dispatchEvent(new MessageEvent("message", { data }));
        for (const port of this.#ports) port.postMessage(data);
      } else if (e.type === "console") {
        console.info(`[VMWorker ${this.name}]`, e.text);
      } else if (e.type === "exit") {
        const failed = e.error ?? (e.code ? `VMWorker ${this.name} exited with code ${e.code}.` : null);
        this.#close(e.code, failed);
      }
    }

    #close(code, error) {
      if (this.#id) workers.delete(this.#id);
      this.#terminated = true;
      for (const port of this.#ports) port.close();
      this.#ports.clear();
      if (error) this.dispatchEvent(new ErrorEvent("error", { message: error }));
      this.dispatchEvent(Object.assign(new Event("exit"), { code }));
      this.#resolveExit({ code, error });
    }
  }

  // onmessage / onmessageerror / onerror / onexit, like Worker's event handler attributes.
  for (const type of ["message", "messageerror", "error", "exit"]) {
    const key = Symbol(type);
    Object.defineProperty(VMWorker.prototype, `on${type}`, {
      get() { return this[key] ?? null; },
      set(fn) {
        if (this[key]) this.removeEventListener(type, this[key]);
        this[key] = typeof fn === "function" ? fn : null;
        if (this[key]) this.addEventListener(type, this[key]);
      },
      configurable: true,
    });
  }

  /** This origin's persistent VM storage root, like navigator.storage.getDirectory() for OPFS. */
  let rootPromise = null;
  Object.defineProperty(VMWorker, "getDirectory", {
    value() {
      rootPromise ??= call("storageRoot", {}).then((url) => new VMFileSystemDirectoryHandle("", url));
      rootPromise.catch(() => (rootPromise = null));
      return rootPromise;
    },
  });

  Object.defineProperty(globalThis, "VMWorker", { value: VMWorker, writable: true, configurable: true });
  // Exposed for tests and for pages that want the same wire format elsewhere.
  Object.defineProperty(VMWorker, "codec", { value: Object.freeze({ encode, decode }) });
  globalThis.__vmworkerEvent = (e) => workers.get(e.id)?.[DISPATCH](e);
})();
