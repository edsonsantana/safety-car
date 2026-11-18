import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import { construirApp } from '../../src/app.ts';
import { bancoFalso, bancoOk, LogCapturado } from '../apoio.ts';

describe('GET /saude', () => {
  test('200 quando o banco responde', async () => {
    const app = construirApp({ banco: bancoOk(), nivelLog: 'silent' });
    const resposta = await app.inject({ method: 'GET', url: '/saude' });
    assert.equal(resposta.statusCode, 200);
    assert.deepEqual(resposta.json(), { status: 'ok', banco: 'ok' });
    assert.equal(resposta.headers['cache-control'], 'no-store');
    await app.close();
  });

  test('503 sem detalhes quando o banco falha', async () => {
    const log = new LogCapturado();
    const falha = Object.assign(new Error('connect ECONNREFUSED 127.0.0.1:5432'), {
      code: 'ECONNREFUSED',
    });
    const app = construirApp({
      banco: bancoFalso(() => Promise.reject(falha)),
      nivelLog: 'info',
      destinoLog: log,
    });
    const resposta = await app.inject({ method: 'GET', url: '/saude' });
    assert.equal(resposta.statusCode, 503);
    assert.deepEqual(resposta.json(), { status: 'degradado', banco: 'indisponivel' });
    assert.ok(!resposta.body.includes('ECONNREFUSED'));
    assert.match(log.texto, /banco indisponível/);
    await app.close();
  });

  test('503 quando o banco não responde dentro do tempo limite', async () => {
    const app = construirApp({
      banco: bancoFalso(() => new Promise(() => undefined)),
      nivelLog: 'silent',
      tempoLimiteSaudeMs: 50,
    });
    const resposta = await app.inject({ method: 'GET', url: '/saude' });
    assert.equal(resposta.statusCode, 503);
    await app.close();
  });

  test('devolve um id de requisição', async () => {
    const app = construirApp({ banco: bancoOk(), nivelLog: 'silent' });
    const resposta = await app.inject({ method: 'GET', url: '/saude' });
    assert.match(String(resposta.headers['x-request-id']), /^[0-9a-f-]{36}$/);
    await app.close();
  });
});
