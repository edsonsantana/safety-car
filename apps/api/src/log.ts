import type { FastifyRequest, FastifyServerOptions } from 'fastify';

/**
 * Chaves que nunca vão para o log, em qualquer nível de aninhamento coberto.
 * Dados pessoais (CPF, e-mail, celular), credenciais e o keycloak_sub (pseudônimo do titular).
 */
export const CHAVES_SENSIVEIS = [
  'cpf',
  'email',
  'celular',
  'telefone',
  'senha',
  'password',
  'token',
  'authorization',
  'cookie',
  'keycloak_sub',
  'keycloakSub',
  'sub',
] as const;

/** Caminhos do redact do pino: a chave na raiz e até três níveis abaixo. */
function caminhosRedacao(): string[] {
  const prefixos = ['', '*.', '*.*.', '*.*.*.'];
  return prefixos.flatMap((prefixo) => CHAVES_SENSIVEIS.map((chave) => `${prefixo}${chave}`));
}

/** Campos de erro do PostgreSQL que podem carregar valores das linhas (ex.: e-mail duplicado). */
const CAMPOS_ERRO_REMOVIDOS = ['detail', 'where', 'internalQuery', 'parameters'];

interface ErroSerializado {
  [chave: string]: unknown;
  type: string;
  message: string;
  stack: string;
}

/** Serializa um erro sem dados de linha: mantém tipo, mensagem, pilha, SQLSTATE e restrição. */
export function serializarErro(erro: unknown): ErroSerializado {
  if (!(erro instanceof Error)) return { type: typeof erro, message: '', stack: '' };
  const saida: ErroSerializado = {
    type: erro.name,
    message: erro.message,
    stack: erro.stack ?? '',
  };
  for (const [chave, valor] of Object.entries(erro)) {
    if (!CAMPOS_ERRO_REMOVIDOS.includes(chave) && typeof valor !== 'object') saida[chave] = valor;
  }
  return saida;
}

/**
 * Opções do logger (pino, embutido no Fastify). Log em JSON; em desenvolvimento o
 * script "dev" passa a saída pelo pino-pretty.
 * - Sem IP, cabeçalhos, URL completa (a query pode ter dado pessoal) nem corpo.
 * - Chaves sensíveis são trocadas por "[removido]".
 */
export function opcoesLog(
  nivel: string,
  destino?: NodeJS.WritableStream,
): NonNullable<FastifyServerOptions['logger']> {
  return {
    level: nivel,
    ...(destino === undefined ? {} : { stream: destino }),
    redact: { paths: caminhosRedacao(), censor: '[removido]' },
    serializers: {
      // Se alguém registrar { req } ou { res }, sai só o mínimo (sem URL, IP nem cabeçalhos).
      req: (req: FastifyRequest) => ({ metodo: req.method, rota: req.routeOptions.url }),
      res: (res: { statusCode: number }) => ({ status: res.statusCode }),
      err: serializarErro,
    },
  };
}
