/**
 * Base das chamadas à API. Em desenvolvimento, "/api" passa pelo proxy do Vite
 * (vite.config.ts), que remove o prefixo e encaminha para API_URL_DEV, sem CORS.
 */
export const API_BASE = (import.meta.env.VITE_API_BASE ?? '/api').replace(/\/+$/, '');
