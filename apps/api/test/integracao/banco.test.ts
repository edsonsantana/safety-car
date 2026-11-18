// Testes contra o banco real em Docker (docker compose up -d + migrações aplicadas).
// Leem o .env da raiz do repositório (script test:integracao).
import assert from 'node:assert/strict';
import { after, before, describe, test } from 'node:test';

import type pg from 'pg';

import { construirApp } from '../../src/app.ts';
import { criarBanco, criarPool, ErroPapelBanco, verificarPapel } from '../../src/banco.ts';
import { carregarConfig, type Config } from '../../src/config.ts';
import { verificadorRecusaTudo } from '../apoio.ts';

let config: Config;
let pool: pg.Pool;

before(async () => {
  config = carregarConfig();
  pool = criarPool(config.banco);
  try {
    await pool.query('SELECT 1');
  } catch (erro) {
    await pool.end();
    const motivo = erro instanceof Error ? erro.message : String(erro);
    throw new Error(
      `Banco inacessível em ${config.banco.host}:${String(config.banco.porta)} (${motivo}). ` +
        'Suba com "docker compose up -d" e aplique as migrações com "bash db/scripts/migrar.sh".',
      { cause: erro },
    );
  }
});

after(async () => {
  await pool.end();
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
