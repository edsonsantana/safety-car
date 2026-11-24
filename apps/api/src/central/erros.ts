import pg from 'pg';

import { ErroApi } from '../erros.ts';

/**
 * Falha numa função ou visão do banco da Central, já SEM a mensagem do PostgreSQL.
 * As mensagens das funções trazem UUIDs e valores (ex.: "ator <uuid> não tem a permissão…",
 * "parâmetro … já vale …"); por isso só o nome da função e o SQLSTATE sobrevivem, e é só isso
 * que vai para o log. A causa original não é guardada.
 */
export class ErroFuncaoBanco extends Error {
  readonly funcao: string;
  readonly sqlstate: string;

  constructor(funcao: string, sqlstate: string) {
    super(`falha em ${funcao} (${sqlstate})`);
    this.name = 'ErroFuncaoBanco';
    this.funcao = funcao;
    this.sqlstate = sqlstate;
  }
}

/** SQLSTATE de um erro do PostgreSQL; "conexao" para falha de rede, pool ou tempo de conexão. */
export function sqlstateDe(erro: unknown): string {
  if (erro instanceof pg.DatabaseError && typeof erro.code === 'string') return erro.code;
  return 'conexao';
}

interface Traducao {
  readonly status: number;
  readonly codigo: string;
  readonly mensagem: string;
}

/** Mesma resposta para sem registro, não operador, inativo, sem permissão e SC016. */
export const ACESSO_NEGADO: Traducao = {
  status: 403,
  codigo: 'acesso_negado',
  mensagem: 'Acesso negado.',
};

const DADOS_INVALIDOS: Traducao = {
  status: 422,
  codigo: 'dados_invalidos',
  mensagem: 'Dados inválidos.',
};
const TENTE_NOVAMENTE: Traducao = {
  status: 409,
  codigo: 'tente_novamente',
  mensagem: 'Conflito com outra operação. Tente novamente.',
};
const INDISPONIVEL: Traducao = {
  status: 503,
  codigo: 'servico_indisponivel',
  mensagem: 'Serviço indisponível no momento.',
};
const ERRO_INTERNO: Traducao = {
  status: 500,
  codigo: 'erro_interno',
  mensagem: 'Erro interno. Tente novamente.',
};

/**
 * SQLSTATE → resposta HTTP. As mensagens são fixas e nunca repetem a do banco.
 * SC029 e SC030 (app escrevendo onde não pode) não deveriam vir da Central: caem no 500.
 * 22023 também significa "inexistente" nas funções; as rotas conferem a existência antes (404).
 */
export const TRADUCOES: Readonly<Record<string, Traducao>> = {
  SC016: ACESSO_NEGADO,
  SC017: {
    status: 403,
    codigo: 'acao_sobre_si_mesmo',
    mensagem: 'Esta ação não pode ser feita sobre o próprio usuário ou pedido.',
  },
  SC013: { status: 409, codigo: 'valor_a_definir', mensagem: 'Há valores ainda a definir.' },
  SC018: {
    status: 409,
    codigo: 'permissao_em_conflito',
    mensagem: 'A permissão já está concedida ou já foi revogada.',
  },
  SC020: { status: 409, codigo: 'ja_decidido', mensagem: 'O pedido já foi decidido.' },
  SC021: { status: 409, codigo: 'regra_futura', mensagem: 'Há regra futura agendada no escopo.' },
  SC023: {
    status: 409,
    codigo: 'ultimo_titular',
    mensagem: 'A Central não pode ficar sem quem administre permissões.',
  },
  SC024: {
    status: 409,
    codigo: 'pedido_em_aberto',
    mensagem: 'Já existe pedido em aberto para este escopo.',
  },
  SC027: {
    status: 409,
    codigo: 'caminho_incorreto',
    mensagem: 'Este parâmetro é alterado por outro caminho.',
  },
  SC028: {
    status: 409,
    codigo: 'regra_ja_definida',
    mensagem: 'A regra já está definida; use o reajuste.',
  },
  SC012: { status: 422, codigo: 'vigencia_invalida', mensagem: 'Vigência inválida.' },
  SC019: {
    status: 422,
    codigo: 'escopo_vazio',
    mensagem: 'Nenhuma regra vigente corresponde ao escopo.',
  },
  SC022: {
    status: 422,
    codigo: 'nada_a_alterar',
    mensagem: 'O resultado é inválido ou não altera nada.',
  },
  SC025: {
    status: 422,
    codigo: 'motivo_excecao_exigido',
    mensagem: 'O percentual passa do limite: informe o motivo da exceção.',
  },
  SC026: {
    status: 422,
    codigo: 'valor_fora_da_faixa',
    mensagem: 'Valor fora da faixa ou do tipo do parâmetro.',
  },
  '22023': DADOS_INVALIDOS,
  '22P02': DADOS_INVALIDOS,
  '23514': DADOS_INVALIDOS,
  '23505': { status: 409, codigo: 'ja_existe', mensagem: 'Já existe um registro com estes dados.' },
  '40P01': TENTE_NOVAMENTE,
  '40001': TENTE_NOVAMENTE,
  '55P03': TENTE_NOVAMENTE,
  '57014': INDISPONIVEL,
  conexao: INDISPONIVEL,
};

export function traduzir(sqlstate: string): Traducao {
  return TRADUCOES[sqlstate] ?? ERRO_INTERNO;
}

export function erroApiDe(traducao: Traducao, cabecalhos: Record<string, string> = {}): ErroApi {
  return new ErroApi(traducao.status, traducao.codigo, traducao.mensagem, cabecalhos);
}
