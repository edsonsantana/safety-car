import type { FastifyInstance } from 'fastify';

import { exigeAutenticacao, type VerificadorToken } from '../autenticacao.ts';
import type { Banco, Perfil } from '../banco.ts';
import { ErroApi } from '../erros.ts';

export interface RespostaMe {
  perfil: Perfil;
  status: 'ativo' | 'pendente';
}

/**
 * GET /me: perfil e status do usuário logado, lidos do banco (usuario.keycloak_sub = sub).
 * Do token só se usa o sub; o perfil vem sempre do banco.
 * - ativo ou pendente: 200 { perfil, status }. O pendente fica separado porque o cadastro em
 *   níveis vai precisar dele; por enquanto o frontend o trata como acesso restrito.
 * - sem registro, suspenso, bloqueado ou excluído: o mesmo 403, pelo mesmo caminho de código,
 *   para não revelar se a conta existe.
 * A resposta não traz e-mail, id nem sub.
 */
export function rotaMe(app: FastifyInstance, verificador: VerificadorToken, banco: Banco): void {
  app.get('/me', { preHandler: exigeAutenticacao(verificador) }, async (req, reply) => {
    void reply.header('cache-control', 'no-store');

    let acesso;
    try {
      acesso = await banco.buscarAcesso(req.keycloakSub);
    } catch (erro) {
      req.log.error({ err: erro }, 'falha ao consultar o usuário');
      throw new ErroApi(503, 'servico_indisponivel', 'Serviço indisponível no momento.');
    }

    if (acesso?.status !== 'ativo' && acesso?.status !== 'pendente') {
      throw new ErroApi(403, 'acesso_restrito', 'Acesso restrito.');
    }
    const resposta: RespostaMe = { perfil: acesso.perfil, status: acesso.status };
    return resposta;
  });
}
