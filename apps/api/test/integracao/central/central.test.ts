// Integração da Central contra o banco DESCARTÁVEL safetycar_api_teste, com as funções reais.
// Rode só pelo script: bash db/scripts/testar_api_central.sh (recria o banco, carrega a semente
// fictícia e o apaga no fim). Tokens assinados com chaves locais (sem Keycloak).
import assert from 'node:assert/strict';
import { after, before, describe, test } from 'node:test';

import type { FastifyInstance } from 'fastify';
import type pg from 'pg';

import { criarPool } from '../../../src/banco.ts';
import {
  type BancoCentral,
  criarBancoCentral,
  criarPoolCentral,
  verificarPapelCentral,
} from '../../../src/central/banco.ts';
import { ErroFuncaoBanco } from '../../../src/central/erros.ts';
import { carregarConfig, type Config } from '../../../src/config.ts';
import { serializarErro } from '../../../src/log.ts';
import {
  type Chaves,
  corpoErro,
  gerarChaves,
  montarAppCentral,
  tokenCentral,
} from '../../apoio-central.ts';

const BANCO_ESPERADO = 'safetycar_api_teste';

// Mesmos valores da semente (apps/api/test/integracao/central/semente.sql).
const id = (n: number) => `00000000-0000-4000-8000-0000000a0a0${String(n)}`;
const sub = (n: number) => `00000000-0000-4000-8000-0000000a0b0${String(n)}`;
const ADMIN = 1;
const SEM_PERMISSAO = 2;
const SUSPENSO = 3;
const SEM_OPERADOR = 4;

let config: Config;
let poolCentral: pg.Pool | undefined;
let poolApp: pg.Pool | undefined;
let banco: BancoCentral;
let chaves: Chaves;
const apps: FastifyInstance[] = [];

before(async () => {
  if (process.env.API_DB_NOME !== BANCO_ESPERADO) {
    throw new Error(
      `Teste da Central só roda no banco descartável ${BANCO_ESPERADO} ` +
        '(use: bash db/scripts/testar_api_central.sh).',
    );
  }
  config = carregarConfig();
  assert.equal(config.banco.nome, BANCO_ESPERADO);
  poolCentral = criarPoolCentral(config.central.banco);
  poolApp = criarPool(config.banco);
  banco = criarBancoCentral(poolCentral);
  chaves = await gerarChaves();
});

after(async () => {
  await Promise.all(apps.map((app) => app.close()));
  await Promise.all([poolCentral?.end(), poolApp?.end()]);
});

/** Pools criados no before (que recusa rodar fora do banco descartável). */
function pools(): { central: pg.Pool; app: pg.Pool } {
  if (poolCentral === undefined || poolApp === undefined) throw new Error('pools não criados');
  return { central: poolCentral, app: poolApp };
}

function montar() {
  const montado = montarAppCentral({ chaves, banco });
  apps.push(montado.app);
  return montado;
}

const bearer = async (n: number) => ({
  authorization: `Bearer ${await tokenCentral(chaves, sub(n))}`,
});

describe('papel e funções do banco da Central', () => {
  test('o pool da Central é o safetycar_central e já executa ator_central', async () => {
    assert.equal(await verificarPapelCentral(pools().central), 'safetycar_central');
  });

  test('o pool do app não executa ator_central (42501)', async () => {
    await assert.rejects(
      pools().app.query('SELECT ator_central($1::uuid)', [sub(ADMIN)]),
      (erro: unknown) => (erro as { code?: string }).code === '42501',
    );
  });

  test('ator_central: id só do operador ativo; NULL nos outros casos', async () => {
    assert.equal(await banco.atorPorSub(sub(ADMIN)), id(ADMIN));
    assert.equal(await banco.atorPorSub(sub(SEM_PERMISSAO)), id(SEM_PERMISSAO));
    assert.equal(await banco.atorPorSub(sub(SUSPENSO)), undefined);
    assert.equal(await banco.atorPorSub(sub(SEM_OPERADOR)), undefined);
    assert.equal(await banco.atorPorSub('00000000-0000-4000-8000-0000000a0b09'), undefined);
  });

  test('operador_tem_permissao e permissões vigentes', async () => {
    assert.equal(await banco.temPermissao(id(ADMIN), 'conceder_permissao'), true);
    assert.equal(await banco.temPermissao(id(SEM_PERMISSAO), 'conceder_permissao'), false);
    assert.deepEqual(await banco.permissoesVigentes(id(ADMIN)), [
      { codigo: 'conceder_permissao', sensivel: true },
    ]);
    assert.deepEqual(await banco.permissoesVigentes(id(SEM_PERMISSAO)), []);
  });

  test('SC016 real vira ErroFuncaoBanco sem a mensagem do banco (que traz o UUID)', async () => {
    const erro = await banco.registrarAcesso(id(SUSPENSO)).then(
      () => assert.fail('o usuário suspenso não registra acesso'),
      (e: unknown) => e,
    );
    assert.ok(erro instanceof ErroFuncaoBanco);
    assert.equal(erro.funcao, 'registrar_acesso_central');
    assert.equal(erro.sqlstate, 'SC016');
    assert.ok(!JSON.stringify(serializarErro(erro)).includes(id(SUSPENSO)));
  });

  test('sub fora do formato: 22P02 do banco, também sem mensagem', async () => {
    const erro = await banco.atorPorSub('nao-e-uuid').catch((e: unknown) => e);
    assert.ok(erro instanceof ErroFuncaoBanco);
    assert.equal(erro.sqlstate, '22P02');
  });
});

describe('rotas da Central com o banco real', () => {
  test('GET /central/eu: permissões do administrador; operador sem permissão recebe lista vazia', async () => {
    const { app } = montar();
    const admin = await app.inject({
      method: 'GET',
      url: '/central/eu',
      headers: await bearer(ADMIN),
    });
    assert.equal(admin.statusCode, 200);
    assert.deepEqual(admin.json<{ permissoes: unknown }>().permissoes, [
      { codigo: 'conceder_permissao', sensivel: true },
    ]);
    const semPermissao = await app.inject({
      method: 'GET',
      url: '/central/eu',
      headers: await bearer(SEM_PERMISSAO),
    });
    assert.deepEqual(semPermissao.json<{ permissoes: unknown }>().permissoes, []);
  });

  test('suspenso e sem cadastro de operador: o mesmo 403', async () => {
    const { app } = montar();
    const respostas = await Promise.all(
      [SUSPENSO, SEM_OPERADOR].map(async (n) =>
        app.inject({ method: 'GET', url: '/central/eu', headers: await bearer(n) }),
      ),
    );
    for (const resposta of respostas) {
      assert.equal(resposta.statusCode, 403);
      assert.deepEqual(corpoErro(resposta), {
        codigo: 'acesso_negado',
        mensagem: 'Acesso negado.',
      });
    }
  });

  test('POST /central/sessao grava o último acesso uma vez por login', async () => {
    const { app, log } = montar();
    const headers = await bearer(ADMIN);
    for (let i = 0; i < 2; i += 1) {
      assert.equal(
        (await app.inject({ method: 'POST', url: '/central/sessao', headers })).statusCode,
        204,
      );
    }
    const { rows } = await pools().central.query<{ ultimo: Date | null }>(
      'SELECT ultimo_acesso_em AS ultimo FROM vw_operador_central WHERE usuario_id = $1',
      [id(ADMIN)],
    );
    assert.ok(rows[0]?.ultimo instanceof Date, 'vw_operador_central mostra o último acesso');
    assert.ok(!log.texto.includes(sub(ADMIN)) && !log.texto.includes(id(ADMIN)));
  });

  test('o acesso entrou uma única vez na auditoria (conferido como migrator)', async (t) => {
    const senha = process.env.SAFETYCAR_MIGRATOR_PASSWORD;
    if (senha === undefined || senha === '') {
      t.skip('SAFETYCAR_MIGRATOR_PASSWORD ausente no .env');
      return;
    }
    const poolMigrator = criarPool({ ...config.banco, usuario: 'safetycar_migrator', senha });
    try {
      const { rows } = await poolMigrator.query<{ total: string }>(
        `SELECT count(*) AS total FROM auditoria
          WHERE acao = 'central_acesso' AND entidade_id = $1 AND papel_bd = 'safetycar_central'`,
        [id(ADMIN)],
      );
      assert.equal(rows[0]?.total, '1');
    } finally {
      await poolMigrator.end();
    }
  });
});
