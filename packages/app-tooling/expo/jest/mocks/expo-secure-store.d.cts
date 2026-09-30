export declare function getItemAsync(key: string): Promise<string | null>;
export declare function setItemAsync(key: string, value: string): Promise<void>;
export declare function deleteItemAsync(key: string): Promise<void>;
/** Clear the store; a test calls it between cases. */
export declare function __reset(): void;
