export interface Service {
  offset: number;
  env: string;
  what: string;
}
export interface PortTable {
  base?: number;
  services?: Record<string, Service>;
  apiPath?: string;
}
export type Ports = { base: number; metro: number; mockApi: number; webPreview: number } & Record<string, number>;

export class PortError extends Error {}
export const BASE_VAR: string;
export const BASE_DEFAULT: number;
export const SERVICES: Record<string, Service>;
export function mockApiUrl(port: number, apiPath?: string): string;
export function portFrom(name: string, value: string | undefined, fallback: number): number;
export function baseFrom(env: Record<string, string | undefined>, fallback?: number): number;
export function resolvePorts(env: Record<string, string | undefined>, table?: PortTable): Ports;
export function envLines(env: Record<string, string | undefined>, table?: PortTable): string[];
export function tableLines(env: Record<string, string | undefined>, table?: PortTable): string[];
