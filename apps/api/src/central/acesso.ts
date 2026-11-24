import type { FastifyRequest } from 'fastify';

import { exigeAutenticacao, type VerificadorToken } from '../autenticacao.ts';
import { ErroApi } from '../erros.ts';
import type { BancoCentral } from './banco.ts';
import { ACESSO_NEGADO, erroApiDe } from './erros.ts';
import type { Limites } from './limite.ts';

/** Operador da Central da requisição (o ator vem SEMPRE do sub do token, nunca do corpo ou da URL). */
export interface ContextoCentral {
  /** usuario.id do operador (ator_central). Nunca vai para o log nem para a resposta. */
  ator: string;
  /** auth_time do token, em segundos. */
  authTime: number;
}

declare module 'fastify' {
  interface FastifyRequest {
    central: ContextoCentral | null;
  }
}

/** Tolerância para auth_time um pouco no futuro (relógios do Keycloak e da API). */
const TOLERANCIA_RELOGIO_S = 5;

/** O MESMO 403 em todos os casos de acesso negado, para não revelar se o operador existe. */
export function acessoNegado(): ErroApi {
  return erroApiDe(ACESSO_NEGADO);
}

function desafio(acr: string, maxAge?: number): string {
  const partes = [
    'Bearer realm="safetycar"',
    'error="insufficient_user_authentication"',
    `acr_values="${acr}"`,
  ];
  if (maxAge !== undefined) partes.push(`max_age=${String(maxAge)}`);
  return partes.join(', ');
}

/** 401 de RFC 9470: o token não tem o nível 2 (senha + OTP). */
export function segundoFatorExigido(acr: string): ErroApi {
  return new ErroApi(
    401,
    'segundo_fator_exigido',
    'Entre com o segundo fator (aplicativo autenticador).',
    { 'www-authenticate': desafio(acr) },
  );
}

/** 401 de RFC 9470: a ação sensível pede OTP de até `segundos` atrás. */
export function otpRecenteExigido(acr: string, segundos: number): ErroApi {
  return new ErroApi(
    401,
    'otp_recente_exigido',
    'Confirme o código do aplicativo autenticador para continuar.',
    { 'www-authenticate': desafio(acr, segundos) },
  );
}

export function limiteExcedido(esperaSegundos: number): ErroApi {
  return new ErroApi(429, 'limite_excedido', 'Muitas requisições. Aguarde e tente de novo.', {
    'retry-after': String(esperaSegundos),
  });
}

/** Contexto preenchido por exigeSessaoCentral; ausente = defeito de montagem da rota (500). */
export function contexto(req: FastifyRequest): ContextoCentral {
  if (req.central === null) throw new Error('rota da Central sem exigeSessaoCentral');
  return req.central;
}

export interface OpcoesSessao {
  verificador: VerificadorToken;
  banco: BancoCentral;
  /** Único acr aceito (nível 2). */
  acr: string;
  limites: Limites;
}

/**
 * preHandler de toda rota /central:
 *  1. token válido do client da Central (401);
 *  2. acr exatamente igual ao nível 2 configurado e auth_time presente (401 RFC 9470);
 *  3. ator pelo sub (ator_central); sem ator = o 403 uniforme;
 *  4. limite por ator: leitura (GET) ou escrita (429).
 */
export function exigeSessaoCentral(opcoes: OpcoesSessao) {
  const autenticar = exigeAutenticacao(opcoes.verificador);
  return async (req: FastifyRequest): Promise<void> => {
    await autenticar(req);
    const identidade = req.identidade;
    if (identidade?.acr !== opcoes.acr || identidade.authTime === undefined) {
      throw segundoFatorExigido(opcoes.acr);
    }
    const ator = await opcoes.banco.atorPorSub(identidade.sub);
    if (ator === undefined) throw acessoNegado();

    const limite = req.method === 'GET' ? opcoes.limites.leitura : opcoes.limites.escrita;
    const espera = limite.consumir(ator);
    if (espera > 0) throw limiteExcedido(espera);

    req.central = { ator, authTime: identidade.authTime };
  };
}

/** preHandler: o ator tem a permissão agora (operador_tem_permissao); se não, o 403 uniforme. */
export function exigePermissao(banco: BancoCentral, permissao: string) {
  return async (req: FastifyRequest): Promise<void> => {
    if (!(await banco.temPermissao(contexto(req).ator, permissao))) throw acessoNegado();
  };
}

/**
 * preHandler das ações sensíveis (★): auth_time de até `segundos` atrás. Como todo login da
 * Central passa pelo OTP (acr de nível 2), um auth_time recente é um OTP recente.
 */
export function exigeOtpRecente(acr: string, segundos: number, agora: () => number = Date.now) {
  return (req: FastifyRequest): Promise<void> => {
    try {
      // auth_time vem em segundos inteiros: compara com o segundo atual, também inteiro.
      const idade = Math.floor(agora() / 1000) - contexto(req).authTime;
      if (idade > segundos || idade < -TOLERANCIA_RELOGIO_S) throw otpRecenteExigido(acr, segundos);
      return Promise.resolve();
    } catch (erro) {
      return Promise.reject(erro instanceof Error ? erro : new Error(String(erro)));
    }
  };
}
