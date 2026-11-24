import type { FastifyInstance, FastifyRequest } from 'fastify';

import type { VerificadorToken } from '../autenticacao.ts';
import { responderErro } from '../erros.ts';
import { exigeSessaoCentral, limiteExcedido } from './acesso.ts';
import type { BancoCentral } from './banco.ts';
import { erroApiDe, ErroFuncaoBanco, traduzir } from './erros.ts';
import { criarLimites, criarPseudonimo, type Limites } from './limite.ts';
import { rotaEu } from './rotas/eu.ts';
import { rotaSessao } from './rotas/sessao.ts';
import { SessoesRegistradas } from './sessoes.ts';

export interface OpcoesCentral {
  banco: BancoCentral;
  /** Verificador com o azp do client da Central (nunca o do app). */
  verificador: VerificadorToken;
  /** Único acr aceito (nível 2: senha + OTP). */
  acr: string;
  /** Idade máxima do auth_time nas ações sensíveis (★). */
  otpRecenteSegundos: number;
  /** Relógio em ms (os testes o controlam). */
  agora?: () => number;
  /** Limites prontos (os testes passam valores menores). */
  limites?: Limites;
}

/** O que as rotas da Central recebem. */
export interface RecursosCentral {
  banco: BancoCentral;
  acr: string;
  otpRecenteSegundos: number;
  agora: () => number;
  sessoes: SessoesRegistradas;
  /** preHandler de sessão (token, acr, ator e limite por ator). */
  sessao: (req: FastifyRequest) => Promise<void>;
}

/**
 * Módulo da Central, sob /central (encapsulado: hooks e tratamento de erros valem só aqui).
 * - Toda resposta: cache-control no-store.
 * - Limite por IP pseudonimizado para respostas 401 e 403; atingido, o IP recebe 429 antes de o
 *   token ser lido. Os limites ficam em memória: valem para uma instância.
 * - Falha de banco: só a função e o SQLSTATE vão para o log; a resposta é a da tabela de tradução.
 */
export function registrarCentral(app: FastifyInstance, opcoes: OpcoesCentral): void {
  const agora = opcoes.agora ?? Date.now;
  const limites = opcoes.limites ?? criarLimites(agora);
  const pseudonimo = criarPseudonimo();

  void app.register(
    (escopo, _opcoes, pronto) => {
      // request.central é decorado no app.ts (null até exigeSessaoCentral preencher).
      escopo.setErrorHandler((erro, req, reply) => {
        if (erro instanceof ErroFuncaoBanco) {
          const traducao = traduzir(erro.sqlstate);
          const dados = { funcao: erro.funcao, sqlstate: erro.sqlstate };
          if (traducao.status >= 500) req.log.error(dados, 'falha no banco da Central');
          else req.log.info(dados, 'banco da Central recusou');
          return responderErro(erroApiDe(traducao), req, reply);
        }
        return responderErro(erro, req, reply);
      });

      escopo.addHook('onRequest', async (req, reply) => {
        void reply.header('cache-control', 'no-store');
        const espera = limites.falhas.excedido(pseudonimo(req.ip));
        if (espera > 0) throw limiteExcedido(espera);
      });

      escopo.addHook('onResponse', async (req, reply) => {
        if (reply.statusCode === 401 || reply.statusCode === 403) {
          limites.falhas.consumir(pseudonimo(req.ip));
        }
      });

      const recursos: RecursosCentral = {
        banco: opcoes.banco,
        acr: opcoes.acr,
        otpRecenteSegundos: opcoes.otpRecenteSegundos,
        agora,
        sessoes: new SessoesRegistradas(agora),
        sessao: exigeSessaoCentral({
          verificador: opcoes.verificador,
          banco: opcoes.banco,
          acr: opcoes.acr,
          limites,
        }),
      };
      rotaEu(escopo, recursos);
      rotaSessao(escopo, recursos);
      pronto();
    },
    { prefix: '/central' },
  );
}
