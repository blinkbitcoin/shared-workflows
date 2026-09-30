/// <reference types="jest" />
export declare const isEnabled: boolean;
export declare const updateId: string | null;
export declare const channel: string | null;
export declare const runtimeVersion: string | null;
export declare const checkForUpdateAsync: jest.Mock<Promise<{ isAvailable: boolean }>, []>;
export declare const fetchUpdateAsync: jest.Mock<Promise<{ isNew: boolean }>, []>;
export declare const reloadAsync: jest.Mock<Promise<void>, []>;
export declare const setUpdateRequestHeadersOverride: jest.Mock;
