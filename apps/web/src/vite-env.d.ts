// Variáveis VITE_* vão para o código do navegador: nunca colocar segredo nelas.
interface ImportMetaEnv {
  readonly VITE_API_BASE?: string;
  /** Endereço do Keycloak, sem /realms (ex.: http://localhost:8180). */
  readonly VITE_KEYCLOAK_URL?: string;
  readonly VITE_KEYCLOAK_REALM?: string;
  /** Client público do frontend (PKCE, sem segredo). */
  readonly VITE_KEYCLOAK_CLIENT_ID?: string;
  /** "true" liga o link "Criar conta" (cadastro pelo Keycloak). */
  readonly VITE_CADASTRO_HABILITADO?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
