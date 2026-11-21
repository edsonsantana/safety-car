export type Perfil = 'tomador' | 'parceiro' | 'central';

/**
 * O que o app sabe sobre o acesso de quem está usando. O perfil vem sempre do banco
 * (GET /me), nunca do token.
 * - verificando: recuperando a sessão ou consultando o /me.
 * - anonimo: sem sessão.
 * - liberado: usuário ativo, com o perfil.
 * - pendente: usuário ainda não liberado (por ora, tratado como acesso restrito).
 * - restrito: sem registro, suspenso, bloqueado ou excluído (a API não diz qual).
 * - indisponivel: API ou Keycloak fora do ar, ou token recusado pela API.
 */
export type Acesso =
  | { tipo: 'verificando' }
  | { tipo: 'anonimo' }
  | { tipo: 'liberado'; perfil: Perfil }
  | { tipo: 'pendente'; perfil: Perfil }
  | { tipo: 'restrito' }
  | { tipo: 'indisponivel' };

/** O que as telas usam da sessão. */
export interface Sessao {
  acesso: Acesso;
  /** Cadastro pelo Keycloak ligado (VITE_CADASTRO_HABILITADO). */
  cadastroHabilitado: boolean;
  /** Vai ao Keycloak para entrar; ao voltar, segue para o destino (caminho interno). */
  entrar: (destino?: string) => Promise<void>;
  /** Vai à tela de cadastro do Keycloak (prompt=create). */
  criarConta: () => Promise<void>;
  /** Trata o retorno do Keycloak em /entrando e devolve o destino. */
  concluirEntrada: () => Promise<string>;
  /** Consulta o /me de novo (depois de uma falha). */
  recarregarPerfil: () => Promise<void>;
  /** Encerra a sessão local e no Keycloak. */
  sair: () => Promise<void>;
  /** Token de acesso atual, só em memória. */
  obterToken: () => string | undefined;
}

/** Início de cada perfil ("Ir para o meu início"). */
export const INICIO_DO_PERFIL: Readonly<Record<Perfil, string>> = {
  tomador: '/tomador',
  parceiro: '/parceiro',
  central: '/central',
};

/**
 * Só caminhos internos: começa com "/" e não com "//" nem "/\" (que o navegador
 * trataria como outro domínio). Qualquer outra coisa vira "/".
 */
export function destinoSeguro(destino: unknown): string {
  if (typeof destino !== 'string') return '/';
  if (!destino.startsWith('/') || destino.startsWith('//') || destino.startsWith('/\\')) return '/';
  return destino;
}
