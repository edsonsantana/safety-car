import type { FastifyInstance } from 'fastify';

import { contexto } from '../acesso.ts';
import type { RecursosCentral } from '../plugin.ts';

/**
 * POST /central/sessao: o frontend chama uma vez depois do login; grava o central_acesso
 * ("último acesso", 0016). A repetição do mesmo login (mesmo sub + auth_time) é ignorada.
 * Sem corpo; 204 nos dois casos.
 */
export function rotaSessao(escopo: FastifyInstance, recursos: RecursosCentral): void {
  escopo.post('/sessao', { preHandler: recursos.sessao }, async (req, reply) => {
    const { ator, authTime } = contexto(req);
    const sub = req.keycloakSub;
    if (recursos.sessoes.reservar(sub, authTime)) {
      try {
        await recursos.banco.registrarAcesso(ator);
      } catch (erro) {
        recursos.sessoes.desfazer(sub, authTime);
        throw erro;
      }
    }
    return reply.code(204).send();
  });
}
