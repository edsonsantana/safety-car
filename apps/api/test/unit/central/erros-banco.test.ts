// Tradução de SQLSTATE e a limpeza do erro do pg (risco 5: nada de mensagem, UUID ou detalhe).
import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import pg from 'pg';

import { criarBancoCentral, type Executor } from '../../../src/central/banco.ts';
import { ErroFuncaoBanco, sqlstateDe, traduzir } from '../../../src/central/erros.ts';
import { serializarErro } from '../../../src/log.ts';
import { uuidTeste } from '../../apoio-central.ts';

const UUID = uuidTeste(0xe1);
const EMAIL = 'operadora-teste@exemplo.invalid';

function erroPg(code: string): pg.DatabaseError {
  const erro = new pg.DatabaseError(
    `ator ${UUID} não tem a permissão "conceder_permissao" vigente`,
    0,
    'error',
  );
  erro.code = code;
  erro.detail = `Key (email)=(${EMAIL}) already exists.`;
  erro.where = `PL/pgSQL function exige_permissao(uuid,text) line 3 at RAISE ${UUID}`;
  return erro;
}

const executorQueFalha = (erro: unknown): Executor => ({
  query: () => Promise.reject(erro instanceof Error ? erro : new Error(String(erro))),
});

describe('tabela de tradução', () => {
  const esperado: Record<string, number> = {
    SC012: 422,
    SC013: 409,
    SC016: 403,
    SC017: 403,
    SC018: 409,
    SC019: 422,
    SC020: 409,
    SC021: 409,
    SC022: 422,
    SC023: 409,
    SC024: 409,
    SC025: 422,
    SC026: 422,
    SC027: 409,
    SC028: 409,
    '22023': 422,
    '22P02': 422,
    '23514': 422,
    '23505': 409,
    '40P01': 409,
    '40001': 409,
    '55P03': 409,
    '57014': 503,
    conexao: 503,
    SC029: 500,
    SC030: 500,
    '42501': 500,
    XX000: 500,
  };
  for (const [sqlstate, status] of Object.entries(esperado)) {
    test(`${sqlstate} → ${String(status)}`, () => {
      assert.equal(traduzir(sqlstate).status, status);
    });
  }

  test('nenhuma mensagem traduzida cita valores, UUIDs ou nomes de função', () => {
    for (const sqlstate of Object.keys(esperado)) {
      assert.doesNotMatch(traduzir(sqlstate).mensagem, /[0-9a-f]{8}-|%|_/);
    }
  });
});

describe('sqlstateDe', () => {
  test('erro do PostgreSQL: o próprio SQLSTATE', () => {
    assert.equal(sqlstateDe(erroPg('SC016')), 'SC016');
  });
  test('erro de rede ou do pool: "conexao", mesmo com code de 5 letras', () => {
    const rede = Object.assign(new Error('write EPIPE'), { code: 'EPIPE' });
    assert.equal(sqlstateDe(rede), 'conexao');
    assert.equal(sqlstateDe(new Error('timeout exceeded when trying to connect')), 'conexao');
  });
});

describe('o erro do pg não passa da camada de banco', () => {
  test('vira ErroFuncaoBanco só com função e SQLSTATE; sem mensagem, detalhe, UUID ou e-mail', async () => {
    const banco = criarBancoCentral(executorQueFalha(erroPg('SC016')));
    const erro = await banco.registrarAcesso(UUID).then(
      () => assert.fail('deveria falhar'),
      (e: unknown) => e,
    );
    assert.ok(erro instanceof ErroFuncaoBanco);
    assert.equal(erro.funcao, 'registrar_acesso_central');
    assert.equal(erro.sqlstate, 'SC016');
    assert.equal(erro.cause, undefined);
    const serializado = JSON.stringify(serializarErro(erro));
    assert.ok(!serializado.includes(UUID), 'sem UUID');
    assert.ok(!serializado.includes(EMAIL), 'sem e-mail');
    assert.ok(!serializado.includes('conceder_permissao'), 'sem a mensagem do banco');
  });

  test('cada operação leva o nome da sua função', async () => {
    const banco = criarBancoCentral(executorQueFalha(erroPg('57014')));
    const nomes = await Promise.all([
      banco.atorPorSub(UUID).catch((e: unknown) => e),
      banco.temPermissao(UUID, 'conceder_permissao').catch((e: unknown) => e),
      banco.permissoesVigentes(UUID).catch((e: unknown) => e),
      banco.registrarAcesso(UUID).catch((e: unknown) => e),
    ]);
    assert.deepEqual(
      nomes.map((e) => (e instanceof ErroFuncaoBanco ? `${e.funcao}:${e.sqlstate}` : 'outro')),
      [
        'ator_central:57014',
        'operador_tem_permissao:57014',
        'vw_operador_permissao:57014',
        'registrar_acesso_central:57014',
      ],
    );
  });

  test('ator_central NULL vira undefined', async () => {
    const banco = criarBancoCentral({
      query: <R extends pg.QueryResultRow>() =>
        Promise.resolve({ rows: [{ ator: null }] } as unknown as pg.QueryResult<R>),
    });
    assert.equal(await banco.atorPorSub(UUID), undefined);
  });
});
