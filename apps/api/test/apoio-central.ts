// Apoio aos testes da Central: chaves RSA locais, tokens no formato do Keycloak e banco falso.
// Valores fictícios: subs e ids 00000000-…, nenhum e-mail real.
import {
  createLocalJWKSet,
  exportJWK,
  generateKeyPair,
  type JWTPayload,
  type JWTVerifyGetKey,
  SignJWT,
} from 'jose';

import { construirApp } from '../src/app.ts';
import { criarVerificadorKeycloak, type VerificadorToken } from '../src/autenticacao.ts';
import type { BancoCentral, PermissaoVigente } from '../src/central/banco.ts';
import type { Limites } from '../src/central/limite.ts';
import { bancoOk, LogCapturado, verificadorRecusaTudo } from './apoio.ts';

export const ISSUER = 'http://localhost:8180/realms/safetycar-dev';
export const AUDIENCE = 'safetycar-api';
export const CLIENT_WEB = 'safetycar-web';
export const CLIENT_CENTRAL = 'safetycar-central';
export const ACR_NIVEL_2 = '2';
export const OTP_RECENTE_S = 600;

export const uuidTeste = (n: number) =>
  `00000000-0000-4000-8000-${n.toString(16).padStart(12, '0')}`;

type ChavePrivada = Awaited<ReturnType<typeof generateKeyPair>>['privateKey'];

export interface Chaves {
  privada: ChavePrivada;
  publicas: JWTVerifyGetKey;
}

export async function gerarChaves(): Promise<Chaves> {
  const par = await generateKeyPair('RS256');
  const jwk = { ...(await exportJWK(par.publicKey)), kid: 'chave-teste', alg: 'RS256' };
  return { privada: par.privateKey, publicas: createLocalJWKSet({ keys: [jwk] }) };
}

/**
 * Token de acesso da Central (typ Bearer, azp da Central, acr de nível 2, auth_time de agora).
 * As claims passadas sobrescrevem as padrão; valor undefined remove a claim.
 */
export async function tokenCentral(
  chaves: Chaves,
  sub: string,
  claims: JWTPayload = {},
  agoraMs: number = Date.now(),
): Promise<string> {
  const agora = Math.floor(agoraMs / 1000);
  const payload: JWTPayload = {
    typ: 'Bearer',
    azp: CLIENT_CENTRAL,
    iss: ISSUER,
    aud: [AUDIENCE],
    sub,
    iat: agora,
    exp: agora + 300,
    acr: ACR_NIVEL_2,
    amr: ['pwd', 'otp'],
    auth_time: agora,
    ...claims,
  };
  for (const [chave, valor] of Object.entries(payload)) {
    if (valor === undefined) Reflect.deleteProperty(payload, chave);
  }
  return new SignJWT(payload)
    .setProtectedHeader({ alg: 'RS256', kid: 'chave-teste', typ: 'JWT' })
    .sign(chaves.privada);
}

/** Verificador da Central com as chaves locais. */
export function verificadorCentral(chaves: Chaves): VerificadorToken {
  return criarVerificadorKeycloak({
    issuer: ISSUER,
    audience: AUDIENCE,
    azp: CLIENT_CENTRAL,
    chaves: chaves.publicas,
  });
}

export interface OpcoesMontagem {
  chaves: Chaves;
  banco: BancoCentral;
  agora?: () => number;
  limites?: Limites;
}

/** App com o módulo da Central, log capturado em nível trace (para conferir o que vaza). */
export function montarAppCentral(opcoes: OpcoesMontagem) {
  const log = new LogCapturado();
  const app = construirApp({
    banco: bancoOk(),
    verificadorToken: verificadorRecusaTudo,
    nivelLog: 'trace',
    destinoLog: log,
    central: {
      banco: opcoes.banco,
      verificador: verificadorCentral(opcoes.chaves),
      acr: ACR_NIVEL_2,
      otpRecenteSegundos: OTP_RECENTE_S,
      ...(opcoes.agora === undefined ? {} : { agora: opcoes.agora }),
      ...(opcoes.limites === undefined ? {} : { limites: opcoes.limites }),
    },
  });
  return { app, log };
}

export const corpoErro = (resposta: { body: string }) =>
  (JSON.parse(resposta.body) as { erro: { codigo: string; mensagem: string } }).erro;

export interface Operador {
  ator: string;
  permissoes: PermissaoVigente[];
}

/** Banco da Central falso: sub → operador; conta as chamadas de registrarAcesso. */
export class BancoCentralFalso implements BancoCentral {
  readonly operadores: Map<string, Operador>;
  readonly acessos: string[] = [];
  /** Se definido, registrarAcesso falha com este erro. */
  falhaRegistro: Error | undefined;

  constructor(operadores = new Map<string, Operador>()) {
    this.operadores = operadores;
  }

  #porAtor(ator: string): Operador | undefined {
    return [...this.operadores.values()].find((o) => o.ator === ator);
  }

  atorPorSub(sub: string) {
    return Promise.resolve(this.operadores.get(sub)?.ator);
  }

  temPermissao(ator: string, permissao: string) {
    return Promise.resolve(
      this.#porAtor(ator)?.permissoes.some((p) => p.codigo === permissao) ?? false,
    );
  }

  permissoesVigentes(ator: string) {
    return Promise.resolve(this.#porAtor(ator)?.permissoes ?? []);
  }

  registrarAcesso(ator: string) {
    if (this.falhaRegistro !== undefined) return Promise.reject(this.falhaRegistro);
    this.acessos.push(ator);
    return Promise.resolve();
  }

  encerrar() {
    return Promise.resolve();
  }
}
