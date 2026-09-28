// VM storage handles: the shape of FileSystemDirectoryHandle / FileSystemFileHandle, backed by the capability
// URLs of CoolWeb's storage server. Injected into pages; Web Workers load the same file:
//
//   importScripts(new URL("/vmfs.js", dir.url));        // classic worker (module worker: await import(...))
//   const root = VMFileSystemHandle.from(e.data.dir);  // a handle posted from the page arrives as {kind, name, url}
//
// Every handle is also plain HTTP: fetch(dir.url + "notes.txt") works from anywhere that can fetch.
(() => {
  if (globalThis.VMFileSystemHandle) return;

  const enc = encodeURIComponent;
  const utf8 = new TextEncoder();

  const checkName = (name) => {
    if (typeof name !== "string" || !name || name === "." || name === ".." || /[/\\\0]/.test(name)) {
      throw new TypeError(`Name is not allowed: ${String(name)}.`);
    }
  };

  async function fail(res, what) {
    const text = await res.text().catch(() => "");
    if (res.status === 404) throw new DOMException(`${what} was not found.`, "NotFoundError");
    if (res.status === 409) throw new DOMException(`${what}: ${text}`, "InvalidModificationError");
    if (res.status === 403) throw new DOMException(`${what}: ${text}`, "NotAllowedError");
    throw new DOMException(`${what}: ${res.status} ${text}`, "InvalidStateError");
  }

  class VMFileSystemHandle {
    // Own enumerable data only, so structured clone (postMessage to a Web Worker) keeps kind, name and url.
    constructor(kind, name, url) {
      this.kind = kind;
      this.name = name;
      this.url = url;
    }

    async isSameEntry(other) {
      return other?.url === this.url;
    }

    /** Restores a handle that crossed postMessage as a plain {kind, name, url} object. */
    static from(value) {
      if (value instanceof VMFileSystemHandle) return value;
      if (value?.kind === "directory") return new VMFileSystemDirectoryHandle(value.name, value.url);
      if (value?.kind === "file") return new VMFileSystemFileHandle(value.name, value.url);
      throw new TypeError("Value is not a VM file system handle.");
    }
  }

  class VMFileSystemDirectoryHandle extends VMFileSystemHandle {
    constructor(name, url) {
      super("directory", name, url);
    }

    async #kindOf(name) {
      const res = await fetch(this.url + enc(name), { method: "HEAD", cache: "no-store" });
      if (res.status === 404) return null;
      if (!res.ok) await fail(res, name);
      return res.headers.get("X-Kind");
    }

    async getDirectoryHandle(name, { create = false } = {}) {
      checkName(name);
      const kind = await this.#kindOf(name);
      if (kind === "file") throw new DOMException(`${name} is a file.`, "TypeMismatchError");
      if (!kind) {
        if (!create) throw new DOMException(`${name} was not found.`, "NotFoundError");
        const res = await fetch(this.url + enc(name) + "/", { method: "PUT" });
        if (!res.ok) await fail(res, name);
      }
      return new VMFileSystemDirectoryHandle(name, this.url + enc(name) + "/");
    }

    async getFileHandle(name, { create = false } = {}) {
      checkName(name);
      const kind = await this.#kindOf(name);
      if (kind === "directory") throw new DOMException(`${name} is a directory.`, "TypeMismatchError");
      if (!kind) {
        if (!create) throw new DOMException(`${name} was not found.`, "NotFoundError");
        const res = await fetch(this.url + enc(name), { method: "PUT", body: new Uint8Array(0) });
        if (!res.ok) await fail(res, name);
      }
      return new VMFileSystemFileHandle(name, this.url + enc(name));
    }

    async removeEntry(name, { recursive = false } = {}) {
      checkName(name);
      const res = await fetch(this.url + enc(name) + (recursive ? "?recursive=1" : ""), { method: "DELETE" });
      if (!res.ok) await fail(res, name);
    }

    /** Path names from this directory to a descendant handle, or null. */
    async resolve(handle) {
      if (!handle?.url?.startsWith(this.url)) return null;
      return handle.url.slice(this.url.length).split("/").filter(Boolean).map(decodeURIComponent);
    }

    async *entries() {
      const res = await fetch(this.url, { cache: "no-store" });
      if (!res.ok) await fail(res, this.name || "Directory");
      for (const e of await res.json()) {
        yield [e.name, e.kind === "directory"
          ? new VMFileSystemDirectoryHandle(e.name, this.url + enc(e.name) + "/")
          : new VMFileSystemFileHandle(e.name, this.url + enc(e.name))];
      }
    }

    async *keys() { for await (const [name] of this.entries()) yield name; }
    async *values() { for await (const [, handle] of this.entries()) yield handle; }
    [Symbol.asyncIterator]() { return this.entries(); }
  }

  class VMFileSystemFileHandle extends VMFileSystemHandle {
    constructor(name, url) {
      super("file", name, url);
    }

    async getFile() {
      const res = await fetch(this.url, { cache: "no-store" });
      if (!res.ok) await fail(res, this.name);
      const lastModified = Number(res.headers.get("X-Last-Modified")) || Date.now();
      return new File([await res.blob()], this.name, { lastModified });
    }

    /** Writes land in a buffer and replace the file atomically on close(), like the spec's swap file. */
    async createWritable({ keepExistingData = false } = {}) {
      const initial = keepExistingData ? new Uint8Array(await (await this.getFile()).arrayBuffer()) : new Uint8Array(0);
      return new VMFileSystemWritableFileStream(this, initial);
    }
  }

  class VMFileSystemWritableFileStream extends WritableStream {
    constructor(handle, initial) {
      let data = initial, size = initial.length, position = 0;
      const reserve = (n) => {
        if (n <= data.length) return;
        const next = new Uint8Array(Math.max(n, data.length * 2, 64));
        next.set(data.subarray(0, size));
        data = next;
      };
      const put = (bytes, at) => {
        reserve(at + bytes.length);
        if (at > size) data.fill(0, size, at);
        data.set(bytes, at);
        size = Math.max(size, at + bytes.length);
        position = at + bytes.length;
      };
      const toBytes = async (d) => {
        if (typeof d === "string") return utf8.encode(d);
        if (d instanceof Blob) return new Uint8Array(await d.arrayBuffer());
        if (d instanceof ArrayBuffer) return new Uint8Array(d);
        if (ArrayBuffer.isView(d)) return new Uint8Array(d.buffer, d.byteOffset, d.byteLength);
        throw new TypeError("Write data must be a string, BufferSource or Blob.");
      };
      super({
        async write(chunk) {
          if (chunk && typeof chunk === "object" && "type" in chunk && !(chunk instanceof Blob)) {
            if (chunk.type === "seek") { position = chunk.position; return; }
            if (chunk.type === "truncate") {
              reserve(chunk.size);
              if (chunk.size > size) data.fill(0, size, chunk.size);
              size = chunk.size;
              position = Math.min(position, size);
              return;
            }
            if (chunk.type === "write") return put(await toBytes(chunk.data), chunk.position ?? position);
            throw new TypeError(`Unknown write type: ${chunk.type}.`);
          }
          put(await toBytes(chunk), position);
        },
        async close() {
          const res = await fetch(handle.url, { method: "PUT", body: data.slice(0, size) });
          if (!res.ok) await fail(res, handle.name);
        },
      });
    }

    async #send(chunk) {
      const writer = this.getWriter();
      try { await writer.write(chunk); } finally { writer.releaseLock(); }
    }

    write(data) { return this.#send(data); }
    seek(position) { return this.#send({ type: "seek", position }); }
    truncate(size) { return this.#send({ type: "truncate", size }); }
  }

  for (const cls of [VMFileSystemHandle, VMFileSystemDirectoryHandle, VMFileSystemFileHandle, VMFileSystemWritableFileStream]) {
    Object.defineProperty(globalThis, cls.name, { value: cls, writable: true, configurable: true });
  }
})();
