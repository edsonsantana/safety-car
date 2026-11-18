import pg from 'pg';

import type { Config } from './config.ts';
import { NOME_SERVICO } from './identidade.ts';

/** O que a API precisa do banco nesta etapa. Interface para os testes trocarem por um falso. */
export interface Banco {
  /** Confere se o banco responde (SELECT 1). Rejeita se não responder. */
  ping(): Promise<void>;
  encerrar(): Promise<void>;
}

/** O papel conectado não serve para a API (superusuário ou com permissão de DDL). */
export class ErroPapelBanco extends Error {
  constructor(mensagem: string) {
    super(mensagem);
    this.name = 'ErroPapelBanco';
  }
}

export function criarPool(config: Config['banco']): pg.Pool {
  return new pg.Pool({
    host: config.host,
    port: config.porta,
    database: config.nome,
    user: config.usuario,
    password: config.senha,
    application_name: NOME_SERVICO,
    max: 10,
    connectionTimeoutMillis: 2_000,
    idleTimeoutMillis: 30_000,
    // Nenhuma consulta da API deve passar disso; protege o banco de consultas presas.
    statement_timeout: 5_000,
  });
}

export function criarBanco(pool: pg.Pool): Banco {
  return {
    async ping() {
      await pool.query('SELECT 1');
    },
    async encerrar() {
      await pool.end();
    },
  };
}

/**
 * Garante, na subida, que a API está conectada com privilégio mínimo:
 * não superusuário e sem CREATE no schema public (ou seja, sem DDL).
 * O safetycar_migrator é dono do schema e por isso é recusado aqui também.
 */
export async function verificarPapel(pool: pg.Pool): Promise<string> {
  const { rows } = await pool.query<{ papel: string; superusuario: boolean; ddl: boolean }>(
    `SELECT current_user AS papel,
            r.rolsuper AS superusuario,
            has_schema_privilege(current_user, 'public', 'CREATE') AS ddl
       FROM pg_roles r
      WHERE r.rolname = current_user`,
  );
  const linha = rows[0];
  if (linha === undefined)
    throw new ErroPapelBanco('não foi possível identificar o papel conectado');
  if (linha.superusuario) {
    throw new ErroPapelBanco(`o papel "${linha.papel}" é superusuário; a API usa o safetycar_app`);
  }
  if (linha.ddl) {
    throw new ErroPapelBanco(
      `o papel "${linha.papel}" pode criar objetos no schema public (DDL); a API usa o safetycar_app`,
    );
  }
  return linha.papel;
}
