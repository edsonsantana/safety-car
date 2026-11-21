import pg from 'pg';

import type { Config } from './config.ts';
import { NOME_SERVICO } from './identidade.ts';

export type Perfil = 'tomador' | 'parceiro' | 'central';
export type StatusUsuario = 'pendente' | 'ativo' | 'suspenso' | 'bloqueado' | 'excluido';

/** O mínimo para decidir o acesso: perfil e status de usuario (CHECK no banco). */
export interface Acesso {
  perfil: Perfil;
  status: StatusUsuario;
}

/** O que a API precisa do banco nesta etapa. Interface para os testes trocarem por um falso. */
export interface Banco {
  /** Confere se o banco responde (SELECT 1). Rejeita se não responder. */
  ping(): Promise<void>;
  /** Perfil e status do usuário vinculado ao sub do Keycloak; undefined se não há registro. */
  buscarAcesso(keycloakSub: string): Promise<Acesso | undefined>;
  encerrar(): Promise<void>;
}

/** Pool ou cliente avulso (o teste de integração usa um cliente dentro de transação). */
interface Executor {
  query<R extends pg.QueryResultRow>(texto: string, valores: unknown[]): Promise<pg.QueryResult<R>>;
}

/** Busca só perfil e status: nada de e-mail, celular ou id sai daqui. */
export async function consultarAcesso(
  executor: Executor,
  keycloakSub: string,
): Promise<Acesso | undefined> {
  const { rows } = await executor.query<Acesso>(
    'SELECT perfil, status FROM usuario WHERE keycloak_sub = $1',
    [keycloakSub],
  );
  return rows[0];
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
    buscarAcesso(keycloakSub) {
      return consultarAcesso(pool, keycloakSub);
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
