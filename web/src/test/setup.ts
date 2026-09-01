Object.defineProperty(window, "localStorage", {
  configurable: true,
  value: { getItem: () => null, setItem: () => undefined, removeItem: () => undefined },
});
HTMLAnchorElement.prototype.click = () => undefined;
