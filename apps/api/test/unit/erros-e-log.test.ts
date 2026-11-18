import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import { construirApp } from '../../src/app.ts';
import { ErroApi } from '../../src/erros.ts';
import { bancoOk, LogCapturado, verificadorRecusaTudo } from '../apoio.ts';

// Valores fictícios, só para conferir que não aparecem no log.
const CPF = '52998224725';
const EMAIL = 'fulana.teste@exemplo.com.br';
const CELULAR = '+5511912345678';

function appComLog() {
  const log = new LogCapturado();
  const app = construirApp({
    verificadorToken: verificadorRecusaTudo,
    banco: bancoOk(),
    nivelLog: 'trace',
    destinoLog: log,
  });
  return { app, log };
}

describe('tratamento central de erros', () => {
  test('404 no formato padrão', async () => {
    const { app } = appComLog();
    const resposta = await app.inject({ method: 'GET', url: '/nao-existe' });
    assert.equal(resposta.statusCode, 404);
    assert.deepEqual(resposta.json(), {
      erro: { codigo: 'nao_encontrado', mensagem: 'Recurso não encontrado.' },
    });
    await app.close();
  });

  test('ErroApi usa o status e o código do próprio erro', async () => {
    const { app } = appComLog();
    app.get('/conflito', () => {
      throw new ErroApi(409, 'conflito', 'Já existe.');
    });
    const resposta = await app.inject({ method: 'GET', url: '/conflito' });
    assert.equal(resposta.statusCode, 409);
    assert.deepEqual(resposta.json(), { erro: { codigo: 'conflito', mensagem: 'Já existe.' } });
    await app.close();
  });

  test('erro inesperado vira 500 genérico; o detalhe fica só no log', async () => {
    const { app, log } = appComLog();
    app.get('/explode', () => {
      throw new Error('falha interna xyz');
    });
    const resposta = await app.inject({ method: 'GET', url: '/explode' });
    assert.equal(resposta.statusCode, 500);
    assert.deepEqual(resposta.json(), {
      erro: { codigo: 'erro_interno', mensagem: 'Erro interno. Tente novamente.' },
    });
    assert.ok(!resposta.body.includes('xyz'));
    assert.match(log.texto, /falha interna xyz/);
    await app.close();
  });

  test('JSON malformado vira 400 genérico', async () => {
    const { app } = appComLog();
    app.post('/eco', () => ({ ok: true }));
    const resposta = await app.inject({
      method: 'POST',
      url: '/eco',
      headers: { 'content-type': 'application/json' },
      payload: '{"cpf": ',
    });
    assert.equal(resposta.statusCode, 400);
    assert.equal(resposta.json<{ erro: { codigo: string } }>().erro.codigo, 'requisicao_invalida');
    await app.close();
  });
});

describe('log sem dados pessoais', () => {
  test('não registra corpo, query, cabeçalhos nem IP', async () => {
    const { app, log } = appComLog();
    app.post('/cadastro-teste', () => ({ ok: true }));
    await app.inject({
      method: 'POST',
      url: `/cadastro-teste?email=${encodeURIComponent(EMAIL)}`,
      headers: { authorization: 'Bearer token-ficticio', cookie: 'sessao=abc' },
      payload: { cpf: CPF, email: EMAIL, celular: CELULAR },
      remoteAddress: '203.0.113.7',
    });
    await app.close();

    for (const proibido of [CPF, EMAIL, CELULAR, 'token-ficticio', 'sessao=abc', '203.0.113.7']) {
      assert.ok(!log.texto.includes(proibido), `o log contém ${proibido}`);
    }
    const concluida = log.registros().find((r) => r.msg === 'requisição concluída');
    assert.deepEqual(
      { metodo: concluida?.metodo, rota: concluida?.rota, status: concluida?.status },
      { metodo: 'POST', rota: '/cadastro-teste', status: 200 },
    );
  });

  test('redige chaves sensíveis registradas por engano, inclusive aninhadas', async () => {
    const { app, log } = appComLog();
    app.get('/registra', (req) => {
      req.log.info(
        { cpf: CPF, usuario: { email: EMAIL, contato: { celular: CELULAR } }, keycloak_sub: 'x' },
        'teste',
      );
      return { ok: true };
    });
    await app.inject({ method: 'GET', url: '/registra' });
    await app.close();

    assert.ok(!log.texto.includes(CPF));
    assert.ok(!log.texto.includes(EMAIL));
    assert.ok(!log.texto.includes(CELULAR));
    const registro = log.registros().find((r) => r.msg === 'teste');
    assert.ok(registro);
    assert.equal(registro.cpf, '[removido]');
    assert.equal(registro.keycloak_sub, '[removido]');
  });

  test('erro do PostgreSQL é registrado sem o "detail" (que traz o valor da linha)', async () => {
    const { app, log } = appComLog();
    app.get('/duplicado', () => {
      throw Object.assign(new Error('duplicate key value violates unique constraint'), {
        code: '23505',
        constraint: 'usuario_email_key',
        detail: `Key (email)=(${EMAIL}) already exists.`,
      });
    });
    const resposta = await app.inject({ method: 'GET', url: '/duplicado' });
    await app.close();

    assert.equal(resposta.statusCode, 500);
    assert.ok(!log.texto.includes(EMAIL));
    assert.match(log.texto, /usuario_email_key/);
    assert.match(log.texto, /23505/);
  });
});
