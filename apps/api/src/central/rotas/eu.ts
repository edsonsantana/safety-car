import type { FastifyInstance } from 'fastify';

import { contexto } from '../acesso.ts';
import type { PermissaoVigente } from '../banco.ts';
import type { RecursosCentral } from '../plugin.ts';

export interface RespostaEu {
  permissoes: PermissaoVigente[];
  otp: {
    /** auth_time dentro da janela de OTP recente (ações sensíveis liberadas sem novo OTP). */
    recente: boolean;
    /** Até quando vale, em ISO 8601; null se já venceu. */
    validoAte: string | null;
  };
}

/**
 * GET /central/eu: permissões efetivas do operador logado e o estado do OTP recente.
 * Sem id, sub, e-mail nem nome: a interface só precisa saber o que mostrar.
 */
export function rotaEu(escopo: FastifyInstance, recursos: RecursosCentral): void {
  escopo.get('/eu', { preHandler: recursos.sessao }, async (req) => {
    const { ator, authTime } = contexto(req);
    const permissoes = await recursos.banco.permissoesVigentes(ator);
    const validoAteS = authTime + recursos.otpRecenteSegundos;
    const recente = Math.floor(recursos.agora() / 1000) <= validoAteS;
    const resposta: RespostaEu = {
      permissoes: permissoes.map(({ codigo, sensivel }) => ({ codigo, sensivel })),
      otp: { recente, validoAte: recente ? new Date(validoAteS * 1000).toISOString() : null },
    };
    return resposta;
  });
}
