import assert from "node:assert/strict";

export class AsyncOperationGate {
  private operation: string | undefined;
  private reachedPromise: Promise<void> = Promise.resolve();
  private releasePromise: Promise<void> = Promise.resolve();
  private signalReached = (): void => undefined;
  private signalRelease = (): void => undefined;

  arm(operation: string): void {
    assert.equal(this.operation, undefined, "an async operation gate is already armed");
    this.operation = operation;
    this.reachedPromise = new Promise<void>((resolve) => {
      this.signalReached = resolve;
    });
    this.releasePromise = new Promise<void>((resolve) => {
      this.signalRelease = resolve;
    });
  }

  async before(operation: string): Promise<void> {
    if (this.operation !== operation) return;
    this.signalReached();
    await this.releasePromise;
    this.operation = undefined;
  }

  async waitUntilReached(): Promise<void> {
    await this.reachedPromise;
    await new Promise<void>((resolve) => { setImmediate(resolve); });
  }

  release(): void {
    this.signalRelease();
  }
}

export function observeSettlement(promise: Promise<unknown>): { readonly settled: () => boolean } {
  let value = false;
  void promise.then(
    () => { value = true; },
    () => { value = true; },
  );
  return { settled: () => value };
}
