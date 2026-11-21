// Testes contra o banco real em Docker (docker compose up -d + migrações aplicadas).
// Leem o .env da raiz do repositório (script test:integracao).
import assert from 'node:assert/strict';
import { after, before, describe, test } from 'node:test';

import type pg from 'pg';

import { construirApp } from '../../src/app.ts';
import {
  consultarAcesso,
  criarBanco,
  criarPool,
  ErroPapelBanco,
  verificarPapel,
} from '../../src/banco.ts';
import { carregarConfig, type Config } from '../../src/config.ts';
import { verificadorRecusaTudo } from '../apoio.ts';

let config: Config;
let pool: pg.Pool;
/** O before() já encerra o pool quando o banco está inacessível. */
let poolEncerrado = false;

before(async () => {
  config = carregarConfig();
  pool = criarPool(config.banco);
  try {
    await pool.query('SELECT 1');
  } catch (erro) {
    await pool.end();
    poolEncerrado = true;
    const motivo = erro instanceof Error ? erro.message : String(erro);
    throw new Error(
      `Banco inacessível em ${config.banco.host}:${String(config.banco.porta)} (${motivo}). ` +
        'Suba com "docker compose up -d" e aplique as migrações com "bash db/scripts/migrar.sh".',
      { cause: erro },
    );
  }
});

after(async () => {
  if (!poolEncerrado) await pool.end();
});

describe('banco real', () => {
  test('a API conecta como safetycar_app, sem superusuário nem DDL', async () => {
    assert.equal(await verificarPapel(pool), 'safetycar_app');
  });

  test('GET /saude responde 200 com o banco no ar', async () => {
    const app = construirApp({
      verificadorToken: verificadorRecusaTudo,
      banco: criarBanco(pool),
      nivelLog: 'silent',
    });
    const resposta = await app.inject({ method: 'GET', url: '/saude' });
    await app.close();
    assert.equal(resposta.statusCode, 200);
    assert.deepEqual(resposta.json(), { status: 'ok', banco: 'ok' });
  });

  test('consultarAcesso lê só perfil e status pelo keycloak_sub (transação desfeita)', async () => {
    // Linhas fictícias; o ROLLBACK as apaga (o safetycar_app não tem DELETE em usuario).
    const cliente = await pool.connect();
    try {
      await cliente.query('BEGIN');
      const subAtivo = '00000000-0000-4000-8000-0000000000a1';
      const subPendente = '00000000-0000-4000-8000-0000000000a2';
      await cliente.query(
        `INSERT INTO usuario (keycloak_sub, email, perfil, status) VALUES
           ($1, 'teste-me-ativo@exemplo.invalid', 'central', 'ativo'),
           ($2, 'teste-me-pendente@exemplo.invalid', 'tomador', 'pendente')`,
        [subAtivo, subPendente],
      );
      assert.deepEqual(await consultarAcesso(cliente, subAtivo), {
        perfil: 'central',
        status: 'ativo',
      });
      assert.deepEqual(await consultarAcesso(cliente, subPendente), {
        perfil: 'tomador',
        status: 'pendente',
      });
      assert.equal(
        await consultarAcesso(cliente, '00000000-0000-4000-8000-0000000000a9'),
        undefined,
      );
    } finally {
      await cliente.query('ROLLBACK');
      cliente.release();
    }
  });

  test('o safetycar_migrator é recusado na verificação de papel', async (t) => {
    const senha = process.env.SAFETYCAR_MIGRATOR_PASSWORD;
    if (senha === undefined || senha === '') {
      t.skip('SAFETYCAR_MIGRATOR_PASSWORD ausente no .env');
      return;
    }
    const poolMigrator = criarPool({ ...config.banco, usuario: 'safetycar_migrator', senha });
    try {
      await assert.rejects(verificarPapel(poolMigrator), (erro: unknown) => {
        assert.ok(erro instanceof ErroPapelBanco);
        assert.match(erro.message, /DDL/);
        return true;
      });
    } finally {
      await poolMigrator.end();
    }
  });
});
