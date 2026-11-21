import {
  InMemoryWebStorage,
  type User,
  UserManager,
  type UserManagerSettings,
  WebStorageStateStore,
} from 'oidc-client-ts';
import type { ConfigKeycloak } from './config.ts';
import { destinoSeguro } from './tipos.ts';

/** Caminhos de retorno do Keycloak (iguais às redirect URIs do client safetycar-web). */
export const CAMINHO_RETORNO = '/entrando';
export const CAMINHO_RENOVACAO = '/renovar-sessao.html';

/**
 * Configuração do oidc-client-ts: Authorization Code com PKCE S256 (padrão da biblioteca),
 * client público, sem segredo.
 * - Tokens só em memória (InMemoryWebStorage): somem no F5 e ao fechar a aba.
 * - O sessionStorage guarda apenas o state, o nonce e o verificador PKCE durante a ida ao
 *   Keycloak (a memória se perde no redirecionamento); a biblioteca os apaga no retorno.
 */
export function opcoesOidc(config: ConfigKeycloak, origem: string): UserManagerSettings {
  return {
    authority: `${config.url}/realms/${encodeURIComponent(config.realm)}`,
    client_id: config.clientId,
    redirect_uri: `${origem}${CAMINHO_RETORNO}`,
    silent_redirect_uri: `${origem}${CAMINHO_RENOVACAO}`,
    post_logout_redirect_uri: `${origem}/`,
    response_type: 'code',
    scope: 'openid',
    ui_locales: 'pt-BR',
    userStore: new WebStorageStateStore({ store: new InMemoryWebStorage() }),
    stateStore: new WebStorageStateStore({
      store: window.sessionStorage,
      prefix: 'safetycar.oidc.',
    }),
    // Renova antes de expirar (com o refresh token em memória, sem iframe).
    automaticSilentRenew: true,
    // O iframe de check-session depende de cookie de terceiros; desligado.
    monitorSession: false,
    // O perfil vem do banco (GET /me); o userinfo não é usado.
    loadUserInfo: false,
    silentRequestTimeoutInSeconds: 5,
  };
}

/** Operações de autenticação que o provedor usa (os testes trocam por um falso). */
export interface ServicoAutenticacao {
  /** Recupera a sessão depois de um F5 (renovação silenciosa). Token ou undefined. */
  restaurar: () => Promise<string | undefined>;
  /** Trata o retorno do Keycloak: token e destino (já validado). */
  concluirEntrada: () => Promise<{ token: string; destino: string }>;
  entrar: (destino: string) => Promise<void>;
  criarConta: () => Promise<void>;
  sair: () => Promise<void>;
  /** Avisa quando o token muda (renovado, expirado ou removido). Devolve o cancelamento. */
  aoMudarToken: (aviso: (token: string | undefined) => void) => () => void;
}

function destinoDoEstado(usuario: User): string {
  const estado = usuario.state;
  const destino =
    typeof estado === 'object' && estado !== null && 'destino' in estado
      ? estado.destino
      : undefined;
  return destinoSeguro(destino);
}

export function criarServicoOidc(
  config: ConfigKeycloak,
  origem: string = window.location.origin,
): ServicoAutenticacao {
  const gerenciador = new UserManager(opcoesOidc(config, origem));

  // No StrictMode os efeitos rodam duas vezes: cada operação de ida e volta roda uma só vez
  // (um segundo signinRedirectCallback falharia: o state já foi consumido).
  let restauracao: Promise<string | undefined> | undefined;
  let conclusao: Promise<{ token: string; destino: string }> | undefined;

  return {
    restaurar() {
      restauracao ??= gerenciador.signinSilent().then(
        (usuario) => usuario?.access_token,
        // login_required, sessão expirada, tempo esgotado: simplesmente sem sessão.
        () => undefined,
      );
      return restauracao;
    },

    concluirEntrada() {
      conclusao ??= gerenciador
        .signinRedirectCallback()
        .then((usuario) => ({ token: usuario.access_token, destino: destinoDoEstado(usuario) }));
      return conclusao;
    },

    entrar(destino) {
      return gerenciador.signinRedirect({ state: { destino: destinoSeguro(destino) } });
    },

    criarConta() {
      return gerenciador.signinRedirect({ prompt: 'create', state: { destino: '/' } });
    },

    async sair() {
      try {
        // Leva o id_token_hint e volta para "/" (post_logout_redirect_uri).
        await gerenciador.signoutRedirect();
      } catch {
        // Sem sessão no Keycloak (ou fora do ar): ao menos encerra a sessão local.
        await gerenciador.removeUser();
        window.location.assign('/');
      }
    },

    aoMudarToken(aviso) {
      const carregado = (usuario: User) => {
        aviso(usuario.access_token);
      };
      const removido = () => {
        aviso(undefined);
      };
      const expirado = () => {
        void gerenciador.removeUser();
      };
      gerenciador.events.addUserLoaded(carregado);
      gerenciador.events.addUserUnloaded(removido);
      gerenciador.events.addAccessTokenExpired(expirado);
      return () => {
        gerenciador.events.removeUserLoaded(carregado);
        gerenciador.events.removeUserUnloaded(removido);
        gerenciador.events.removeAccessTokenExpired(expirado);
      };
    },
  };
}
