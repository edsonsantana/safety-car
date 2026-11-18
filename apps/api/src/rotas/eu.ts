import type { FastifyInstance } from 'fastify';

import { exigeAutenticacao, type VerificadorToken } from '../autenticacao.ts';

export interface RespostaEu {
  keycloak_sub: string;
}

/** GET /eu: rota de exemplo autenticada. Devolve só o sub do token; não cria usuário. */
export function rotaEu(app: FastifyInstance, verificador: VerificadorToken): void {
  app.get('/eu', { preHandler: exigeAutenticacao(verificador) }, async (req, reply) => {
    void reply.header('cache-control', 'no-store');
    const resposta: RespostaEu = { keycloak_sub: req.keycloakSub };
    return resposta;
  });
}
