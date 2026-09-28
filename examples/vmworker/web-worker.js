// A plain Web Worker. It gets a MessagePort to the VM from the page (vm.connect()) and talks to it directly.
// Replies from the VM reach every connected port, so this worker uses its own id range.
let vm = null;
let nextId = 100000;
const pending = new Map();

onmessage = (e) => {
  if (e.data.vm) {
    vm = e.data.vm;
    vm.onmessage = ({ data }) => {
      const sentAt = pending.get(data?.id);
      if (sentAt === undefined) return;
      pending.delete(data.id);
      postMessage({ ...data, rttMs: +(performance.now() - sentAt).toFixed(1) });
    };
    return;
  }
  if (e.data.cmd && vm) {
    const id = nextId++;
    pending.set(id, performance.now());
    vm.postMessage({ id, cmd: e.data.cmd });
  }
};
