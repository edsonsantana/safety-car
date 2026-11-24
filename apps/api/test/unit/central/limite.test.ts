// Limite de requisições em memória (uma instância): janela fixa, por ator e por IP de falhas.
import assert from 'node:assert/strict';
import { after, before, describe, test } from 'node:test';

import type { FastifyInstance } from 'fastify';

import { criarLimites, criarPseudonimo, LimiteJanela } from '../../../src/central/limite.ts';
import {
  BancoCentralFalso,
  type Chaves,
  corpoErro,
  gerarChaves,
  montarAppCentral,
  tokenCentral,
  uuidTeste,
} from '../../apoio-central.ts';

describe('LimiteJanela', () => {
  test('conta até o máximo, recusa com a espera e reabre na janela seguinte', () => {
    let agora = 1_000_000;
    const limite = new LimiteJanela(3, 60_000, () => agora);
    assert.deepEqual([limite.consumir('a'), limite.consumir('a'), limite.consumir('a')], [0, 0, 0]);
    assert.equal(limite.consumir('a'), 60);
    agora += 45_500;
    assert.equal(limite.consumir('a'), 15);
    assert.equal(limite.consumir('b'), 0, 'cada chave conta à parte');
    agora += 14_500;
    assert.equal(limite.consumir('a'), 0, 'janela nova');
  });

  test('excedido só consulta, não conta', () => {
    const limite = new LimiteJanela(1, 60_000, () => 0);
    assert.equal(limite.excedido('a'), 0);
    assert.equal(limite.excedido('a'), 0);
    limite.consumir('a');
    assert.equal(limite.excedido('a'), 60);
  });

  test('número de chaves limitado: saem as vencidas e, se preciso, a mais antiga', () => {
    let agora = 0;
    const limite = new LimiteJanela(5, 1_000, () => agora, 3);
    for (const chave of ['a', 'b', 'c']) limite.consumir(chave);
    agora = 2_000;
    limite.consumir('d');
    assert.equal(limite.tamanho, 1, 'as três vencidas saíram');
    for (const chave of ['e', 'f']) limite.consumir(chave);
    limite.consumir('g');
    assert.equal(limite.tamanho, 3, 'a mais antiga saiu para caber a nova');
  });
});

describe('pseudônimo', () => {
  test('estável no processo e sem o valor original', () => {
    const p = criarPseudonimo();
    assert.equal(p('127.0.0.1'), p('127.0.0.1'));
    assert.notEqual(p('127.0.0.1'), p('127.0.0.2'));
    assert.ok(!p('127.0.0.1').includes('127.0.0.1'));
    assert.notEqual(criarPseudonimo()('127.0.0.1'), p('127.0.0.1'), 'chave nova a cada subida');
  });
});

describe('limites nas rotas', () => {
  const SUB = uuidTeste(0xf1);
  let chaves: Chaves;
  const apps: FastifyInstance[] = [];
  before(async () => {
    chaves = await gerarChaves();
  });
  after(async () => {
    await Promise.all(apps.map((app) => app.close()));
  });

  function montar(valores: {
    leituraPorMinuto: number;
    escritaPorMinuto: number;
    falhasPorMinuto: number;
  }) {
    const banco = new BancoCentralFalso(
      new Map([[SUB, { ator: uuidTeste(0xf2), permissoes: [] }]]),
    );
    const montado = montarAppCentral({ chaves, banco, limites: criarLimites(Date.now, valores) });
    apps.push(montado.app);
    return montado.app;
  }

  test('leitura por ator: passou do limite, 429 com retry-after', async () => {
    const app = montar({ leituraPorMinuto: 2, escritaPorMinuto: 10, falhasPorMinuto: 10 });
    const headers = { authorization: `Bearer ${await tokenCentral(chaves, SUB)}` };
    const status = [];
    for (let i = 0; i < 3; i += 1) {
      status.push((await app.inject({ method: 'GET', url: '/central/eu', headers })).statusCode);
    }
    assert.deepEqual(status, [200, 200, 429]);
    const recusada = await app.inject({ method: 'GET', url: '/central/eu', headers });
    assert.equal(corpoErro(recusada).codigo, 'limite_excedido');
    assert.match(String(recusada.headers['retry-after']), /^\d+$/);
  });

  test('escrita por ator tem limite próprio', async () => {
    const app = montar({ leituraPorMinuto: 10, escritaPorMinuto: 1, falhasPorMinuto: 10 });
    const headers = { authorization: `Bearer ${await tokenCentral(chaves, SUB)}` };
    assert.equal(
      (await app.inject({ method: 'POST', url: '/central/sessao', headers })).statusCode,
      204,
    );
    assert.equal(
      (await app.inject({ method: 'POST', url: '/central/sessao', headers })).statusCode,
      429,
    );
    assert.equal(
      (await app.inject({ method: 'GET', url: '/central/eu', headers })).statusCode,
      200,
    );
  });

  test('falhas (401/403) por IP: atingido o limite, nem o token válido passa', async () => {
    const app = montar({ leituraPorMinuto: 10, escritaPorMinuto: 10, falhasPorMinuto: 2 });
    assert.equal((await app.inject({ method: 'GET', url: '/central/eu' })).statusCode, 401);
    const desconhecido = `Bearer ${await tokenCentral(chaves, uuidTeste(0xf9))}`;
    assert.equal(
      (
        await app.inject({
          method: 'GET',
          url: '/central/eu',
          headers: { authorization: desconhecido },
        })
      ).statusCode,
      403,
    );
    const valido = { authorization: `Bearer ${await tokenCentral(chaves, SUB)}` };
    const resposta = await app.inject({ method: 'GET', url: '/central/eu', headers: valido });
    assert.equal(resposta.statusCode, 429);
    assert.equal(resposta.headers['cache-control'], 'no-store');
  });
});
