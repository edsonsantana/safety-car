/**
 * Configuração do Keycloak no navegador (variáveis VITE_*, públicas: nunca segredo).
 * O client é público, com PKCE: não existe segredo de cliente.
 */
export interface ConfigKeycloak {
  /** Endereço do Keycloak, sem o /realms (ex.: http://localhost:8180). */
  url: string;
  realm: string;
  clientId: string;
  /** "Criar conta" leva ao cadastro do Keycloak; desligado, mostra "em breve". */
  cadastroHabilitado: boolean;
}

type Ambiente = Partial<Record<string, string | boolean | undefined>>;

function texto(valor: unknown, padrao: string): string {
  return typeof valor === 'string' && valor.trim() !== '' ? valor.trim() : padrao;
}

export function lerConfigKeycloak(ambiente: Ambiente = import.meta.env): ConfigKeycloak {
  return {
    url: texto(ambiente.VITE_KEYCLOAK_URL, 'http://localhost:8180').replace(/\/+$/, ''),
    realm: texto(ambiente.VITE_KEYCLOAK_REALM, 'safetycar-dev'),
    clientId: texto(ambiente.VITE_KEYCLOAK_CLIENT_ID, 'safetycar-web'),
    cadastroHabilitado: ambiente.VITE_CADASTRO_HABILITADO === 'true',
  };
}
