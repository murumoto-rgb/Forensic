/** Poll only after the previous tick settles, so slow jobs cannot accumulate
 * callbacks or overlap. Idle/error scans back off; claimed work resets latency. */
export function startQueuePoller(
  tick: () => Promise<boolean>,
  onError: (error: unknown) => void,
): () => void {
  const initialDelay = 5_000;
  const maxDelay = 60_000;
  let delay = initialDelay;
  let stopped = false;
  let timer: ReturnType<typeof setTimeout>;

  const run = async () => {
    let didWork = false;
    try {
      didWork = await tick();
    } catch (error) {
      onError(error);
    } finally {
      delay = didWork ? initialDelay : Math.min(delay * 2, maxDelay);
      if (!stopped) timer = setTimeout(() => { void run(); }, delay);
    }
  };
  timer = setTimeout(() => { void run(); }, delay);
  return () => {
    stopped = true;
    clearTimeout(timer);
  };
}
