import type { FastifyRequest } from 'fastify';
import { createRemoteJWKSet, errors as errosJose, jwtVerify, type JWTVerifyGetKey } from 'jose';

import { ErroApi } from './erros.ts';

declare module 'fastify' {
  interface FastifyRequest {
    /** sub do token do Keycloak (= usuario.keycloak_sub). Preenchido por exigeAutenticacao. */
    keycloakSub: string;
    /** Claims de autenticação do token. Preenchido por exigeAutenticacao. */
    identidade: Identidade | null;
  }
}

/**
 * O que a API usa de um token já validado. Nada de e-mail, nome ou papéis do Keycloak.
 * - acr: nível de autenticação ("Authentication Context Class Reference"); só texto.
 * - amr: métodos usados (ex.: pwd, otp); lista vazia se ausente ou fora do formato.
 * - authTime: auth_time em segundos desde a época (última autenticação interativa).
 */
export interface Identidade {
  sub: string;
  acr: string | undefined;
  amr: readonly string[];
  authTime: number | undefined;
}

/** Valida um token de acesso e devolve a identidade. */
export interface VerificadorToken {
  verificar(token: string): Promise<Identidade>;
}

/** Token recusado (assinatura, emissor, audiência, validade ou formato). */
export class TokenInvalido extends Error {
  constructor(motivo: string, opcoes?: ErrorOptions) {
    super(motivo, opcoes);
    this.name = 'TokenInvalido';
  }
}

/** Não foi possível obter as chaves públicas do Keycloak (fora do ar, tempo esgotado). */
export class AutenticacaoIndisponivel extends Error {
  constructor(opcoes?: ErrorOptions) {
    super('chaves públicas do Keycloak indisponíveis', opcoes);
    this.name = 'AutenticacaoIndisponivel';
  }
}

const FORMATO_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export interface OpcoesVerificador {
  issuer: string;
  audience: string;
  /** Client que pediu o token ("azp"); só tokens emitidos para o nosso frontend. */
  azp: string;
  /** Chaves de verificação. Padrão: JWKS remoto do realm (os testes passam chaves locais). */
  chaves?: JWTVerifyGetKey;
}

/**
 * Falha ao obter o JWKS (rede, tempo esgotado, resposta não 200 ou JSON inválido): não é culpa
 * do token. O jose usa o JOSEError genérico (ERR_JOSE_GENERIC) para resposta HTTP não 200.
 */
function falhaAoObterChaves(erro: unknown): boolean {
  if (!(erro instanceof errosJose.JOSEError)) return true;
  return (
    erro instanceof errosJose.JWKSTimeout ||
    erro instanceof errosJose.JWKSInvalid ||
    erro.code === 'ERR_JOSE_GENERIC'
  );
}

/** JWKS remoto do realm. Um só por processo: os verificadores do app e da Central o dividem. */
export function criarChavesKeycloak(issuer: string): JWTVerifyGetKey {
  return createRemoteJWKSet(new URL(`${issuer}/protocol/openid-connect/certs`), {
    timeoutDuration: 2_000,
    cooldownDuration: 30_000,
    cacheMaxAge: 10 * 60_000,
  });
}

/** Extrai acr, amr e auth_time sem confiar no formato: o que não for do tipo esperado é descartado. */
function claimsDeAutenticacao(payload: Record<string, unknown>): Omit<Identidade, 'sub'> {
  const { acr, amr, auth_time: authTime } = payload;
  return {
    acr: typeof acr === 'string' ? acr : undefined,
    amr: Array.isArray(amr) ? amr.filter((m): m is string => typeof m === 'string') : [],
    authTime:
      typeof authTime === 'number' && Number.isSafeInteger(authTime) && authTime > 0
        ? authTime
        : undefined,
  };
}

export function criarVerificadorKeycloak(opcoes: OpcoesVerificador): VerificadorToken {
  const chaves = opcoes.chaves ?? criarChavesKeycloak(opcoes.issuer);

  return {
    async verificar(token) {
      let payload;
      try {
        ({ payload } = await jwtVerify(token, chaves, {
          issuer: opcoes.issuer,
          audience: opcoes.audience,
          // Só assinatura assimétrica: impede "alg: none" e HS256 com a chave pública.
          algorithms: ['RS256'],
          requiredClaims: ['sub', 'exp', 'iat'],
          clockTolerance: 5,
        }));
      } catch (erro) {
        if (falhaAoObterChaves(erro)) throw new AutenticacaoIndisponivel({ cause: erro });
        throw new TokenInvalido(erro instanceof errosJose.JOSEError ? erro.code : 'erro', {
          cause: erro,
        });
      }

      // Keycloak marca o token de acesso com typ "Bearer"; recusa ID token e refresh token.
      if (payload.typ !== 'Bearer') throw new TokenInvalido('typ diferente de Bearer');
      if (payload.azp !== opcoes.azp) throw new TokenInvalido('azp diferente do client esperado');
      const sub = payload.sub;
      if (sub === undefined || !FORMATO_UUID.test(sub)) {
        throw new TokenInvalido('sub ausente ou fora do formato uuid');
      }
      return { sub, ...claimsDeAutenticacao(payload) };
    },
  };
}

const DESAFIO = 'Bearer realm="safetycar"';

/** Extrai o token de "Authorization: Bearer <token>". */
function tokenDoCabecalho(valor: string | undefined): string | undefined {
  if (valor === undefined) return undefined;
  const partes = /^Bearer[ ]+([A-Za-z0-9\-._~+/]+=*)$/i.exec(valor.trim());
  return partes?.[1];
}

/**
 * preHandler que exige token válido do Keycloak e expõe request.keycloakSub e request.identidade.
 * 401 sem token ou com token inválido; 503 se o Keycloak não fornece as chaves.
 * O sub e o token nunca vão para o log.
 */
export function exigeAutenticacao(verificador: VerificadorToken) {
  return async (req: FastifyRequest): Promise<void> => {
    const token = tokenDoCabecalho(req.headers.authorization);
    if (token === undefined) {
      throw new ErroApi(401, 'nao_autenticado', 'Autenticação necessária.', {
        'www-authenticate': DESAFIO,
      });
    }
    try {
      const identidade = await verificador.verificar(token);
      req.identidade = identidade;
      req.keycloakSub = identidade.sub;
    } catch (erro) {
      if (erro instanceof TokenInvalido) {
        req.log.info({ motivo: erro.message }, 'token recusado');
        throw new ErroApi(401, 'token_invalido', 'Token inválido ou expirado.', {
          'www-authenticate': `${DESAFIO}, error="invalid_token"`,
        });
      }
      req.log.error({ err: erro }, 'autenticação indisponível');
      throw new ErroApi(503, 'autenticacao_indisponivel', 'Autenticação indisponível no momento.');
    }
  };
}
