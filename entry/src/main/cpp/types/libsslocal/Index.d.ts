export const start: (configJson: string) => number;
export const startTunFd: (configJson: string, tunFd: number) => number;
export const setStatAddress: (addr: string) => number;
export const stop: () => number;
export const isRunning: () => boolean;
export const lastError: () => string | null;
export const version: () => string;
