import type { FastifyInstance } from 'fastify';

import type { Banco } from '../banco.ts';

export interface RespostaSaude {
  status: 'ok' | 'degradado';
  banco: 'ok' | 'indisponivel';
}

class TempoEsgotado extends Error {
  constructor(ms: number) {
    super(`sem resposta em ${String(ms)} ms`);
    this.name = 'TempoEsgotado';
  }
}

async function comTempoLimite<T>(promessa: Promise<T>, ms: number): Promise<T> {
  let temporizador: NodeJS.Timeout | undefined;
  const limite = new Promise<never>((_, rejeitar) => {
    temporizador = setTimeout(() => {
      rejeitar(new TempoEsgotado(ms));
    }, ms);
  });
  try {
    return await Promise.race([promessa, limite]);
  } finally {
    clearTimeout(temporizador);
  }
}

/** GET /saude: pública. 200 se a API e o banco respondem; 503 se o banco não responde. */
export function rotaSaude(app: FastifyInstance, banco: Banco, tempoLimiteMs: number): void {
  app.get('/saude', async (req, reply): Promise<RespostaSaude> => {
    void reply.header('cache-control', 'no-store');
    try {
      await comTempoLimite(banco.ping(), tempoLimiteMs);
      return { status: 'ok', banco: 'ok' };
    } catch (erro) {
      req.log.warn({ err: erro }, 'banco indisponível');
      void reply.code(503);
      return { status: 'degradado', banco: 'indisponivel' };
    }
  });
}
