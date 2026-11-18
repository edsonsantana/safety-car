import type { FastifyInstance } from 'fastify';

/** Corpo padrão de erro de toda a API. */
export interface CorpoErro {
  erro: { codigo: string; mensagem: string };
}

/** Erro esperado, com status HTTP e código estável para o cliente. */
export class ErroApi extends Error {
  readonly status: number;
  readonly codigo: string;
  /** Cabeçalhos extras da resposta (ex.: WWW-Authenticate no 401). */
  readonly cabecalhos: Readonly<Record<string, string>>;

  constructor(
    status: number,
    codigo: string,
    mensagem: string,
    cabecalhos: Readonly<Record<string, string>> = {},
  ) {
    super(mensagem);
    this.name = 'ErroApi';
    this.status = status;
    this.codigo = codigo;
    this.cabecalhos = cabecalhos;
  }
}

export function corpoErro(codigo: string, mensagem: string): CorpoErro {
  return { erro: { codigo, mensagem } };
}

function statusDoErro(erro: unknown): number | undefined {
  if (typeof erro !== 'object' || erro === null || !('statusCode' in erro)) return undefined;
  const status = erro.statusCode;
  return typeof status === 'number' ? status : undefined;
}

/**
 * Tratamento central de erros.
 * - ErroApi: status e código do próprio erro.
 * - Erros 4xx do Fastify (corpo inválido, tipo de conteúdo etc.): mensagem genérica.
 * - Qualquer outro: 500 genérico; o detalhe fica só no log (já sem dados de linha).
 * Ponto previsto para mapear os SQLSTATE da classe SC (regras do banco) mais adiante.
 */
export function registrarTratamentoErros(app: FastifyInstance): void {
  app.setErrorHandler((erro, req, reply) => {
    if (erro instanceof ErroApi) {
      return reply
        .code(erro.status)
        .headers(erro.cabecalhos)
        .send(corpoErro(erro.codigo, erro.message));
    }

    const status = statusDoErro(erro);
    if (status !== undefined && status >= 400 && status < 500) {
      req.log.info({ err: erro }, 'requisição rejeitada');
      return reply.code(status).send(corpoErro('requisicao_invalida', 'Requisição inválida.'));
    }

    req.log.error({ err: erro }, 'erro não tratado');
    return reply.code(500).send(corpoErro('erro_interno', 'Erro interno. Tente novamente.'));
  });

  app.setNotFoundHandler((_req, reply) =>
    reply.code(404).send(corpoErro('nao_encontrado', 'Recurso não encontrado.')),
  );
}
