-- 25 — ator_central (0021): forma da função e privilégios (como safetycar_migrator).
-- (O nome não termina em _central.sql de propósito: esse sufixo faz o testar.sh rodar como a Central.)
-- O comportamento é testado pelo próprio papel da Central em 25_ator_central_central.sql.

SELECT pg_temp.confere(
  (SELECT p.prosecdef FROM pg_proc p WHERE p.oid = 'ator_central(uuid)'::regprocedure),
  'ator_central é SECURITY DEFINER');
SELECT pg_temp.confere(
  (SELECT p.proconfig = ARRAY['search_path=public, pg_temp'] FROM pg_proc p
    WHERE p.oid = 'ator_central(uuid)'::regprocedure),
  'ator_central tem search_path fixo (public, pg_temp)');
SELECT pg_temp.confere(
  (SELECT p.provolatile = 's' AND NOT p.proisstrict FROM pg_proc p
    WHERE p.oid = 'ator_central(uuid)'::regprocedure),
  'ator_central é STABLE (não escreve) e não STRICT (o EXECUTE é conferido até com sub nulo)');
SELECT pg_temp.confere(
  pg_get_function_result('ator_central(uuid)'::regprocedure) = 'uuid'
  AND pg_get_function_arguments('ator_central(uuid)'::regprocedure) = 'p_keycloak_sub uuid',
  'ator_central recebe só o sub e devolve só um uuid (sem e-mail nem status)');
SELECT pg_temp.confere(
  (SELECT pg_get_userbyid(p.proowner) = 'safetycar_migrator' FROM pg_proc p
    WHERE p.oid = 'ator_central(uuid)'::regprocedure),
  'dono da função é o safetycar_migrator');

-- Privilégios: só o dono e o safetycar_central; nada para PUBLIC nem para o app.
SELECT pg_temp.confere(
  (SELECT array_agg(g.papel ORDER BY g.papel)
     FROM (SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee)::text END AS papel
             FROM pg_proc p, aclexplode(p.proacl) a
            WHERE p.oid = 'ator_central(uuid)'::regprocedure AND a.privilege_type = 'EXECUTE') g)
  = ARRAY['safetycar_central', 'safetycar_migrator']::text[],
  'EXECUTE só para safetycar_central (e o dono); nenhum para PUBLIC');
SELECT pg_temp.confere(
  NOT has_function_privilege('safetycar_app', 'ator_central(uuid)', 'EXECUTE'),
  'safetycar_app não executa ator_central');
SELECT pg_temp.confere(
  NOT has_table_privilege('safetycar_central', 'usuario', 'SELECT'),
  'safetycar_central continua sem SELECT em usuario');
