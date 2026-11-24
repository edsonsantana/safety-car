// GET /central/eu e POST /central/sessao, tradução de SQLSTATE e o que vai para o log.
import assert from 'node:assert/strict';
import { after, before, describe, test } from 'node:test';

import type { FastifyInstance } from 'fastify';

import { ErroFuncaoBanco } from '../../../src/central/erros.ts';
import {
  BancoCentralFalso,
  type Chaves,
  corpoErro,
  gerarChaves,
  montarAppCentral,
  tokenCentral,
  uuidTeste,
} from '../../apoio-central.ts';

const SUB = uuidTeste(0xb1);
const ATOR = uuidTeste(0xd1);

let chaves: Chaves;
const apps: FastifyInstance[] = [];
before(async () => {
  chaves = await gerarChaves();
});
after(async () => {
  await Promise.all(apps.map((app) => app.close()));
});

function montar(agora: () => number = Date.now) {
  const banco = new BancoCentralFalso(
    new Map([
      [
        SUB,
        {
          ator: ATOR,
          permissoes: [
            { codigo: 'aprovar_reajuste_taxa', sensivel: true },
            { codigo: 'solicitar_reajuste_taxa', sensivel: false },
          ],
        },
      ],
    ]),
  );
  const montado = montarAppCentral({ chaves, banco, agora });
  apps.push(montado.app);
  return { ...montado, banco };
}

const bearer = (token: string) => ({ authorization: `Bearer ${token}` });

describe('GET /central/eu', () => {
  test('permissões efetivas e OTP recente; sem id, sub nem e-mail na resposta', async () => {
    const agora = Date.now();
    const { app } = montar(() => agora);
    const authTime = Math.floor(agora / 1000) - 100;
    const token = await tokenCentral(chaves, SUB, { auth_time: authTime }, agora);
    const resposta = await app.inject({
      method: 'GET',
      url: '/central/eu',
      headers: bearer(token),
    });
    assert.equal(resposta.statusCode, 200);
    assert.equal(resposta.headers['cache-control'], 'no-store');
    assert.deepEqual(resposta.json(), {
      permissoes: [
        { codigo: 'aprovar_reajuste_taxa', sensivel: true },
        { codigo: 'solicitar_reajuste_taxa', sensivel: false },
      ],
      otp: { recente: true, validoAte: new Date((authTime + 600) * 1000).toISOString() },
    });
    assert.ok(!resposta.body.includes(SUB) && !resposta.body.includes(ATOR));
  });

  test('OTP vencido: recente false e validoAte null (a leitura continua liberada)', async () => {
    const agora = Date.now();
    const { app } = montar(() => agora);
    const token = await tokenCentral(
      chaves,
      SUB,
      { auth_time: Math.floor(agora / 1000) - 700 },
      agora,
    );
    const resposta = await app.inject({
      method: 'GET',
      url: '/central/eu',
      headers: bearer(token),
    });
    assert.equal(resposta.statusCode, 200);
    assert.deepEqual(resposta.json<{ otp: unknown }>().otp, {
      recente: false,
      validoAte: null,
    });
  });
});

describe('POST /central/sessao', () => {
  test('registra uma vez por login: o mesmo sub + auth_time é ignorado', async () => {
    const { app, banco } = montar();
    const agora = Math.floor(Date.now() / 1000);
    const primeiro = await tokenCentral(chaves, SUB, { auth_time: agora - 10 });
    for (let i = 0; i < 3; i += 1) {
      const resposta = await app.inject({
        method: 'POST',
        url: '/central/sessao',
        headers: bearer(primeiro),
      });
      assert.equal(resposta.statusCode, 204);
      assert.equal(resposta.body, '');
    }
    assert.deepEqual(banco.acessos, [ATOR]);

    const novoLogin = await tokenCentral(chaves, SUB, { auth_time: agora });
    const resposta = await app.inject({
      method: 'POST',
      url: '/central/sessao',
      headers: bearer(novoLogin),
    });
    assert.equal(resposta.statusCode, 204);
    assert.deepEqual(banco.acessos, [ATOR, ATOR]);
  });

  test('se a gravação falha, o login não fica marcado: a próxima chamada grava', async () => {
    const { app, banco } = montar();
    const token = await tokenCentral(chaves, SUB);
    banco.falhaRegistro = new ErroFuncaoBanco('registrar_acesso_central', 'conexao');
    const falhou = await app.inject({
      method: 'POST',
      url: '/central/sessao',
      headers: bearer(token),
    });
    assert.equal(falhou.statusCode, 503);
    assert.equal(corpoErro(falhou).codigo, 'servico_indisponivel');

    banco.falhaRegistro = undefined;
    const gravou = await app.inject({
      method: 'POST',
      url: '/central/sessao',
      headers: bearer(token),
    });
    assert.equal(gravou.statusCode, 204);
    assert.deepEqual(banco.acessos, [ATOR]);
  });
});

describe('SQLSTATE das funções → HTTP, e o log só com função e SQLSTATE', () => {
  const casos: [string, number, string][] = [
    ['SC016', 403, 'acesso_negado'],
    ['SC017', 403, 'acao_sobre_si_mesmo'],
    ['SC020', 409, 'ja_decidido'],
    ['SC023', 409, 'ultimo_titular'],
    ['40P01', 409, 'tente_novamente'],
    ['55P03', 409, 'tente_novamente'],
    ['22023', 422, 'dados_invalidos'],
    ['57014', 503, 'servico_indisponivel'],
    ['conexao', 503, 'servico_indisponivel'],
    ['SC029', 500, 'erro_interno'],
    ['XX000', 500, 'erro_interno'],
  ];
  for (const [sqlstate, status, codigo] of casos) {
    test(`${sqlstate} → ${String(status)} ${codigo}`, async () => {
      const { app, banco, log } = montar();
      banco.falhaRegistro = new ErroFuncaoBanco('registrar_acesso_central', sqlstate);
      const token = await tokenCentral(chaves, SUB);
      const resposta = await app.inject({
        method: 'POST',
        url: '/central/sessao',
        headers: bearer(token),
      });
      assert.equal(resposta.statusCode, status);
      assert.equal(corpoErro(resposta).codigo, codigo);

      // Risco 5 do plano: o registro de falha traz só função e SQLSTATE.
      const registro = log
        .registros()
        .find((r) => r.msg === 'banco da Central recusou' || r.msg === 'falha no banco da Central');
      assert.ok(registro !== undefined, 'a falha do banco foi registrada');
      assert.equal(registro.funcao, 'registrar_acesso_central');
      assert.equal(registro.sqlstate, sqlstate);
      assert.equal(registro.err, undefined, 'nenhum objeto de erro no registro');
      assert.ok(!log.texto.includes(SUB), 'o sub não aparece no log');
      assert.ok(!log.texto.includes(ATOR), 'o ator não aparece no log');
      assert.ok(!log.texto.includes(token), 'o token não aparece no log');
    });
  }
});
