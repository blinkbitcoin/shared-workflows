declare const Storage: {
  getItem(key: string): Promise<string | null>;
  setItem(key: string, value: string): Promise<void>;
  removeItem(key: string): Promise<void>;
  /** Clear the store; a test calls it between cases. */
  __reset(): void;
};
export default Storage;
