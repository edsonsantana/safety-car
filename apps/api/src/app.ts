import { randomUUID } from 'node:crypto';

import Fastify, { type FastifyInstance, LogController } from 'fastify';

import type { VerificadorToken } from './autenticacao.ts';
import type { Banco } from './banco.ts';
import { type OpcoesCentral, registrarCentral } from './central/plugin.ts';
import { registrarTratamentoErros } from './erros.ts';
import { opcoesLog } from './log.ts';
import { rotaMe } from './rotas/me.ts';
import { rotaSaude } from './rotas/saude.ts';

export interface OpcoesApp {
  banco: Banco;
  verificadorToken: VerificadorToken;
  nivelLog: string;
  /** Destino do log (os testes capturam aqui); padrão: saída padrão. */
  destinoLog?: NodeJS.WritableStream;
  /** Tempo máximo do SELECT 1 do /saude. */
  tempoLimiteSaudeMs?: number;
  /** Módulo da Central (/central). Ausente: as rotas não existem (testes de outras rotas). */
  central?: OpcoesCentral;
}

/** Monta a aplicação sem abrir porta (os testes usam app.inject). */
export function construirApp(opcoes: OpcoesApp): FastifyInstance {
  const app = Fastify({
    logger: opcoesLog(opcoes.nivelLog, opcoes.destinoLog),
    // Um único registro por requisição (onResponse abaixo), sem URL, IP nem cabeçalhos.
    logController: new LogController({
      disableRequestLogging: true,
      requestIdLogLabel: 'requisicao',
    }),
    genReqId: () => randomUUID(),
    bodyLimit: 64 * 1024,
  });

  app.addHook('onRequest', async (req, reply) => {
    void reply.header('x-request-id', req.id);
  });

  app.addHook('onResponse', async (req, reply) => {
    req.log.info(
      {
        metodo: req.method,
        rota: req.routeOptions.url ?? '(sem rota)',
        status: reply.statusCode,
        duracao_ms: Math.round(reply.elapsedTime),
      },
      'requisição concluída',
    );
  });

  registrarTratamentoErros(app);
  app.decorateRequest('keycloakSub', '');
  app.decorateRequest('identidade', null);
  app.decorateRequest('central', null);

  rotaSaude(app, opcoes.banco, opcoes.tempoLimiteSaudeMs ?? 2_000);
  rotaMe(app, opcoes.verificadorToken, opcoes.banco);
  if (opcoes.central !== undefined) registrarCentral(app, opcoes.central);

  return app;
}
