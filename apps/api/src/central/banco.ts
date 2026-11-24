import pg from 'pg';

import { ErroPapelBanco } from '../banco.ts';
import type { Config } from '../config.ts';
import { NOME_SERVICO } from '../identidade.ts';
import { ErroFuncaoBanco, sqlstateDe } from './erros.ts';

export interface PermissaoVigente {
  codigo: string;
  sensivel: boolean;
}

/**
 * O que o módulo da Central usa do banco, sempre pelo papel safetycar_central.
 * Toda falha vira ErroFuncaoBanco (nome da função + SQLSTATE, sem a mensagem do banco).
 * Interface para os testes trocarem por um falso.
 */
export interface BancoCentral {
  /** usuario.id do operador ativo com este sub (0021); undefined em qualquer outro caso. */
  atorPorSub(keycloakSub: string): Promise<string | undefined>;
  /** O ator tem a permissão agora? (operador_tem_permissao, 0014). */
  temPermissao(ator: string, permissao: string): Promise<boolean>;
  /** Permissões efetivas do ator, em ordem de código. */
  permissoesVigentes(ator: string): Promise<PermissaoVigente[]>;
  /** Evento central_acesso (0016). */
  registrarAcesso(ator: string): Promise<void>;
  encerrar(): Promise<void>;
}

/** Pool ou cliente avulso. */
export interface Executor {
  query<R extends pg.QueryResultRow>(texto: string, valores: unknown[]): Promise<pg.QueryResult<R>>;
}

/** Executa e, em caso de erro, troca o erro do pg por ErroFuncaoBanco (sem mensagem nem detalhe). */
export async function executar<R extends pg.QueryResultRow>(
  executor: Executor,
  funcao: string,
  texto: string,
  valores: unknown[],
): Promise<R[]> {
  try {
    return (await executor.query<R>(texto, valores)).rows;
  } catch (erro) {
    throw new ErroFuncaoBanco(funcao, sqlstateDe(erro));
  }
}

export function criarBancoCentral(
  executor: Executor,
  encerrar: () => Promise<void> = () => Promise.resolve(),
): BancoCentral {
  return {
    async atorPorSub(keycloakSub) {
      const linhas = await executar<{ ator: string | null }>(
        executor,
        'ator_central',
        'SELECT ator_central($1::uuid) AS ator',
        [keycloakSub],
      );
      return linhas[0]?.ator ?? undefined;
    },
    async temPermissao(ator, permissao) {
      const linhas = await executar<{ tem: boolean }>(
        executor,
        'operador_tem_permissao',
        'SELECT operador_tem_permissao($1::uuid, $2) AS tem',
        [ator, permissao],
      );
      return linhas[0]?.tem === true;
    },
    permissoesVigentes(ator) {
      return executar<PermissaoVigente>(
        executor,
        'vw_operador_permissao',
        `SELECT permissao_codigo AS codigo, sensivel
           FROM vw_operador_permissao
          WHERE operador_id = $1::uuid AND efetiva
          ORDER BY permissao_codigo`,
        [ator],
      );
    },
    async registrarAcesso(ator) {
      await executar(
        executor,
        'registrar_acesso_central',
        'SELECT registrar_acesso_central($1::uuid)',
        [ator],
      );
    },
    encerrar,
  };
}

/** Pool do safetycar_central: separado do pool do app, menor e com lock_timeout. */
export function criarPoolCentral(config: Config['central']['banco']): pg.Pool {
  return new pg.Pool({
    host: config.host,
    port: config.porta,
    database: config.nome,
    user: config.usuario,
    password: config.senha,
    application_name: `${NOME_SERVICO}-central`,
    max: 5,
    connectionTimeoutMillis: 2_000,
    idleTimeoutMillis: 30_000,
    statement_timeout: 5_000,
    // As aprovações esperam advisory lock e FOR UPDATE: melhor 409 "tente novamente" do que
    // estourar o statement_timeout.
    lock_timeout: 3_000,
  });
}

/**
 * Confere, na subida, o papel do pool da Central: é o safetycar_central, sem superusuário nem
 * DDL, continua sem ler usuario e já executa ator_central (migração 0021 aplicada).
 */
export async function verificarPapelCentral(pool: Executor): Promise<string> {
  const { rows } = await pool.query<{
    papel: string;
    superusuario: boolean;
    ddl: boolean;
    le_usuario: boolean;
    ator_central: boolean | null;
  }>(
    `SELECT current_user AS papel,
            r.rolsuper AS superusuario,
            has_schema_privilege(current_user, 'public', 'CREATE') AS ddl,
            has_table_privilege(current_user, 'usuario', 'SELECT') AS le_usuario,
            CASE WHEN to_regprocedure('ator_central(uuid)') IS NULL THEN NULL
                 ELSE has_function_privilege(current_user, to_regprocedure('ator_central(uuid)'), 'EXECUTE')
            END AS ator_central
       FROM pg_roles r
      WHERE r.rolname = current_user`,
    [],
  );
  const linha = rows[0];
  if (linha === undefined)
    throw new ErroPapelBanco('não foi possível identificar o papel conectado');
  if (linha.papel !== 'safetycar_central') {
    throw new ErroPapelBanco(
      `o pool da Central conectou como "${linha.papel}"; use o safetycar_central`,
    );
  }
  if (linha.superusuario || linha.ddl) {
    throw new ErroPapelBanco(
      'o safetycar_central não pode ser superusuário nem ter DDL no schema public',
    );
  }
  if (linha.le_usuario) {
    throw new ErroPapelBanco('o safetycar_central não deveria ler a tabela usuario (0014 a 0021)');
  }
  if (linha.ator_central !== true) {
    throw new ErroPapelBanco(
      'o safetycar_central não executa ator_central: aplique a migração 0021 (bash db/scripts/migrar.sh)',
    );
  }
  return linha.papel;
}
