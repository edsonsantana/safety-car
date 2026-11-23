-- 20 — Permissões da Central (0016), como safetycar_migrator (dono das funções).
-- Catálogo ampliado, último titular de conceder_permissao (SC023), eventos de auditoria com nome
-- próprio, acesso à Central e falha da auditoria desfazendo a operação.
-- Usuários FICTÍCIOS: A, B e C de perfil central; T tomador.

INSERT INTO usuario (id, keycloak_sub, email, perfil, status) VALUES
  ('00000000-0000-4000-8000-0000000c0e01', gen_random_uuid(), 'perm-a@exemplo.invalid', 'central', 'ativo'),
  ('00000000-0000-4000-8000-0000000c0e02', gen_random_uuid(), 'perm-b@exemplo.invalid', 'central', 'ativo'),
  ('00000000-0000-4000-8000-0000000c0e03', gen_random_uuid(), 'perm-c@exemplo.invalid', 'central', 'ativo'),
  ('00000000-0000-4000-8000-0000000c0e09', gen_random_uuid(), 'perm-t@exemplo.invalid', 'tomador', 'ativo');

CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $f$
  SELECT ('00000000-0000-4000-8000-0000000c0e0' || CASE p WHEN 'A' THEN '1' WHEN 'B' THEN '2' WHEN 'C' THEN '3' ELSE '9' END)::uuid
$f$;

-- Concessão vigente (id) de uma permissão a um operador.
CREATE FUNCTION pg_temp.vigente(p_operador uuid, p_permissao text) RETURNS uuid LANGUAGE sql STABLE AS $f$
  SELECT c.id FROM permissao_concessao c
   WHERE c.operador_id = p_operador AND c.permissao_codigo = p_permissao
     AND NOT EXISTS (SELECT 1 FROM permissao_revogacao r WHERE r.concessao_id = c.id)
$f$;

-- ---------- Catálogo ----------
SELECT pg_temp.confere(
  (SELECT array_agg(codigo ORDER BY codigo) FROM permissao_central)
    = '{administrar_parametros,analisar_cadastros,aprovar_reajuste_taxa,conceder_permissao,solicitar_reajuste_taxa}',
  'catálogo com as 5 permissões (conceder_permissao = administrar permissões; aprovar_reajuste_taxa = aprovar tarifa)');
SELECT pg_temp.confere(
  (SELECT array_agg(codigo ORDER BY codigo) FROM permissao_central WHERE sensivel)
    = '{administrar_parametros,aprovar_reajuste_taxa,conceder_permissao}',
  'sensíveis: administrar permissões, aprovar reajuste e administrar parâmetros');
SELECT pg_temp.confere(
  (SELECT nome = 'Administrar permissões' FROM permissao_central WHERE codigo = 'conceder_permissao'),
  'conceder_permissao mantém o código e ganha o rótulo do desenho');
SELECT pg_temp.confere(
  NOT EXISTS (SELECT 1 FROM permissao_central WHERE permite_autoaprovacao),
  'nenhuma permissão admite autoaprovação');
SELECT pg_temp.espera_erro($$UPDATE permissao_central SET sensivel = false WHERE codigo = 'conceder_permissao'$$,
  '23514', 'conceder_permissao é sempre sensível');
SELECT pg_temp.confere(
  (SELECT count(*) = 3 FROM auditoria
    WHERE entidade = 'permissao_central' AND acao = 'parametrizacao_insert' AND papel_bd = 'safetycar_migrator'
      AND depois ->> 'codigo' IN ('solicitar_reajuste_taxa','analisar_cadastros','administrar_parametros')),
  'as permissões novas entraram na auditoria (papel safetycar_migrator)');

-- ---------- Equipe ----------
SELECT conceder_permissao_inicial(pg_temp.u('A'), '[TESTE] primeiro administrador');
SELECT cadastrar_operador(pg_temp.u('A'), pg_temp.u('B'), '[TESTE] equipe');
SELECT cadastrar_operador(pg_temp.u('A'), pg_temp.u('C'), '[TESTE] equipe');

-- ---------- Único titular (A) ----------
SELECT pg_temp.espera_erro($$SELECT revogar_permissao(pg_temp.u('A'), pg_temp.u('A'), 'conceder_permissao', '[TESTE] abdica')$$,
  'SC023', 'o único titular não revoga a própria conceder_permissao');
SELECT pg_temp.espera_erro($$
  INSERT INTO permissao_revogacao (concessao_id, revogada_por, motivo, origem)
  VALUES (pg_temp.vigente(pg_temp.u('A'), 'conceder_permissao'), pg_temp.u('A'), '[TESTE] direto', 'operador')$$,
  'SC023', 'a regra vale também para INSERT direto (trigger)');
SELECT pg_temp.espera_erro($$UPDATE operador_central SET ativo = false WHERE usuario_id = pg_temp.u('A')$$,
  'SC023', 'o único titular não é desativado, nem por UPDATE direto');
SELECT pg_temp.confere(operador_tem_permissao(pg_temp.u('A'), 'conceder_permissao'),
  'A continua titular efetivo');

-- ---------- Dois titulares; inativo e suspenso não contam ----------
SELECT pg_temp.aceita($$SELECT conceder_permissao(pg_temp.u('A'), pg_temp.u('B'), 'conceder_permissao', '[TESTE] segundo titular')$$,
  'A concede conceder_permissao a B');
SELECT pg_temp.aceita($$SELECT definir_operador_ativo(pg_temp.u('B'), pg_temp.u('A'), false, '[TESTE] afastamento')$$,
  'com outro titular (B), A pode ser desativado');
SELECT pg_temp.espera_erro($$SELECT revogar_permissao(pg_temp.u('B'), pg_temp.u('B'), 'conceder_permissao', '[TESTE] abdica')$$,
  'SC023', 'titular de operador inativo (A) não conta como outro titular');
SELECT pg_temp.espera_erro($$UPDATE operador_central SET ativo = false WHERE usuario_id = pg_temp.u('B')$$,
  'SC023', 'B, agora único titular efetivo, não é desativado');
SELECT pg_temp.aceita($$SELECT definir_operador_ativo(pg_temp.u('B'), pg_temp.u('A'), true, '[TESTE] retorno')$$,
  'B reativa A');

UPDATE usuario SET status = 'suspenso' WHERE id = pg_temp.u('A');
SELECT pg_temp.espera_erro($$SELECT revogar_permissao(pg_temp.u('B'), pg_temp.u('B'), 'conceder_permissao', '[TESTE] abdica')$$,
  'SC023', 'titular com usuário suspenso (A) não conta como outro titular');
SELECT pg_temp.aceita($$SELECT revogar_permissao(pg_temp.u('B'), pg_temp.u('A'), 'conceder_permissao', '[TESTE] titular suspenso')$$,
  'revogar um titular que já não é efetivo é permitido (não reduz quem administra)');
UPDATE usuario SET status = 'ativo' WHERE id = pg_temp.u('A');

SELECT pg_temp.aceita($$SELECT conceder_permissao(pg_temp.u('B'), pg_temp.u('C'), 'conceder_permissao', '[TESTE] troca de titular')$$,
  'B concede conceder_permissao a C');
SELECT pg_temp.aceita($$SELECT revogar_permissao(pg_temp.u('C'), pg_temp.u('B'), 'conceder_permissao', '[TESTE] troca de titular')$$,
  'com C titular, a permissão de B pode ser revogada');
SELECT pg_temp.confere(
  (SELECT count(*) = 1 FROM vw_permissao_vigente WHERE permissao_codigo = 'conceder_permissao' AND efetiva)
  AND operador_tem_permissao(pg_temp.u('C'), 'conceder_permissao'),
  'sobra exatamente um titular efetivo (C)');

-- ---------- Outras permissões não têm a regra ----------
SELECT pg_temp.aceita($$SELECT conceder_permissao(pg_temp.u('C'), pg_temp.u('B'), 'aprovar_reajuste_taxa', '[TESTE] aprovador')$$,
  'C concede aprovar_reajuste_taxa a B');
SELECT pg_temp.aceita($$SELECT revogar_permissao(pg_temp.u('B'), pg_temp.u('B'), 'aprovar_reajuste_taxa', '[TESTE] abdica')$$,
  'o último aprovador pode abdicar (a regra é só de conceder_permissao)');

-- ---------- Recuperação manual continua liberada ----------
SELECT pg_temp.aceita($$SELECT revogar_permissao_manual(pg_temp.u('C'), 'conceder_permissao', '[TESTE] emergência')$$,
  'revogação manual do último titular (recuperação da 0014) não passa pela SC023');
SELECT pg_temp.confere(pg_temp.vigente(pg_temp.u('C'), 'conceder_permissao') IS NULL
  AND NOT EXISTS (SELECT 1 FROM vw_permissao_vigente WHERE permissao_codigo = 'conceder_permissao'),
  'ninguém mais tem conceder_permissao');
SELECT pg_temp.aceita($$SELECT conceder_permissao_inicial(pg_temp.u('A'), '[TESTE] recuperação')$$,
  'sem titular, a concessão inicial volta a valer');
SELECT pg_temp.espera_erro($$SELECT conceder_permissao_inicial(pg_temp.u('B'), '[TESTE] segunda inicial')$$,
  'SC018', 'SC018 da concessão inicial continua igual');

-- ---------- Eventos de auditoria com nome próprio ----------
SELECT pg_temp.confere(
  EXISTS (SELECT 1 FROM auditoria a JOIN permissao_concessao c ON c.id = a.entidade_id
           WHERE a.acao = 'central_permissao_concedida' AND a.entidade = 'permissao_concessao'
             AND a.ator_usuario_id = pg_temp.u('A') AND c.operador_id = pg_temp.u('B')
             AND a.depois ->> 'operador_id' = pg_temp.u('B')::text
             AND a.depois ->> 'permissao_codigo' = 'conceder_permissao'
             AND a.depois ->> 'motivo' = '[TESTE] segundo titular'
             AND a.papel_bd = 'safetycar_migrator'),
  'central_permissao_concedida com ator, quem recebeu, permissão e motivo');
SELECT pg_temp.confere(
  EXISTS (SELECT 1 FROM auditoria a JOIN permissao_revogacao r ON r.id = a.entidade_id
           WHERE a.acao = 'central_permissao_revogada' AND a.entidade = 'permissao_revogacao'
             AND a.ator_usuario_id = pg_temp.u('B') AND r.motivo = '[TESTE] titular suspenso'
             AND (a.antes ->> 'vigente')::boolean AND NOT (a.depois ->> 'vigente')::boolean
             AND a.depois ->> 'operador_id' = pg_temp.u('A')::text),
  'central_permissao_revogada com ator e vigência antes e depois');
SELECT pg_temp.confere(
  NOT EXISTS (SELECT 1 FROM permissao_concessao c WHERE c.origem = 'operador'
               AND NOT EXISTS (SELECT 1 FROM auditoria a WHERE a.acao = 'central_permissao_concedida' AND a.entidade_id = c.id))
  AND NOT EXISTS (SELECT 1 FROM permissao_revogacao r WHERE r.origem = 'operador'
               AND NOT EXISTS (SELECT 1 FROM auditoria a WHERE a.acao = 'central_permissao_revogada' AND a.entidade_id = r.id)),
  'toda concessão e revogação feita por operador tem o seu evento');
SELECT pg_temp.confere(
  NOT EXISTS (SELECT 1 FROM permissao_revogacao r JOIN auditoria a ON a.entidade_id = r.id
               WHERE r.origem = 'manual' AND a.acao = 'central_permissao_revogada'),
  'a revogação manual fica só na auditoria automática (papel migrator, sem ator)');

-- ---------- Acesso à Central ----------
SELECT pg_temp.espera_erro($$SELECT registrar_acesso_central(pg_temp.u('T'))$$,
  'SC016', 'acesso de quem não é operador é recusado');
SELECT pg_temp.espera_erro($$SELECT registrar_acesso_central(NULL)$$,
  'SC016', 'acesso sem ator é recusado');
SELECT pg_temp.aceita($$SELECT registrar_acesso_central(pg_temp.u('A'))$$, 'acesso de A registrado');
SELECT pg_temp.confere(
  (SELECT ultimo_acesso_em IS NOT NULL FROM vw_operador_central WHERE usuario_id = pg_temp.u('A'))
  AND (SELECT ultimo_acesso_em IS NULL FROM vw_operador_central WHERE usuario_id = pg_temp.u('B')),
  'vw_operador_central mostra o último acesso de A e nenhum de B');
SELECT pg_temp.aceita($$SELECT definir_operador_ativo(pg_temp.u('A'), pg_temp.u('B'), false, '[TESTE] afastamento')$$,
  'A desativa B (B não é titular)');
SELECT pg_temp.espera_erro($$SELECT registrar_acesso_central(pg_temp.u('B'))$$,
  'SC016', 'operador inativo não registra acesso');
SELECT definir_operador_ativo(pg_temp.u('A'), pg_temp.u('B'), true, '[TESTE] retorno');

-- ---------- Visão do histórico ----------
SELECT pg_temp.confere(
  (SELECT count(*) = 2 FROM vw_operador_permissao WHERE operador_id = pg_temp.u('A') AND permissao_codigo = 'conceder_permissao')
  AND EXISTS (SELECT 1 FROM vw_operador_permissao WHERE operador_id = pg_temp.u('A') AND permissao_codigo = 'conceder_permissao'
               AND NOT vigente AND NOT efetiva AND revogada_por = pg_temp.u('B') AND origem_revogacao = 'operador')
  AND EXISTS (SELECT 1 FROM vw_operador_permissao WHERE operador_id = pg_temp.u('A') AND permissao_codigo = 'conceder_permissao'
               AND vigente AND efetiva AND origem_concessao = 'inicial' AND sensivel),
  'vw_operador_permissao: concessão revogada e concessão vigente de A, com quem revogou');

-- ---------- Falha da auditoria desfaz a operação ----------
-- Trigger de teste (some no ROLLBACK): falha todo INSERT em auditoria quando teste.falhar_auditoria = sim.
CREATE FUNCTION public.teste_falhar_auditoria() RETURNS trigger LANGUAGE plpgsql AS $f$
BEGIN
  IF current_setting('teste.falhar_auditoria', true) = 'sim' THEN
    RAISE EXCEPTION '[TESTE] auditoria indisponível' USING ERRCODE = 'TS001';
  END IF;
  RETURN NEW;
END $f$;
CREATE TRIGGER tg_teste_falhar_auditoria BEFORE INSERT ON auditoria
  FOR EACH ROW EXECUTE FUNCTION public.teste_falhar_auditoria();

SELECT conceder_permissao(pg_temp.u('A'), pg_temp.u('B'), 'solicitar_reajuste_taxa', '[TESTE] solicitante');
SET LOCAL teste.falhar_auditoria = 'sim';
SELECT pg_temp.espera_erro($$SELECT conceder_permissao(pg_temp.u('A'), pg_temp.u('B'), 'administrar_parametros', '[TESTE] falha')$$,
  'TS001', 'concessão com a auditoria falhando é recusada');
SELECT pg_temp.confere(pg_temp.vigente(pg_temp.u('B'), 'administrar_parametros') IS NULL,
  'a concessão não ficou gravada');
SELECT pg_temp.espera_erro($$SELECT revogar_permissao(pg_temp.u('A'), pg_temp.u('B'), 'solicitar_reajuste_taxa', '[TESTE] falha')$$,
  'TS001', 'revogação com a auditoria falhando é recusada');
SELECT pg_temp.confere(pg_temp.vigente(pg_temp.u('B'), 'solicitar_reajuste_taxa') IS NOT NULL,
  'a revogação não ficou gravada');
SELECT pg_temp.espera_erro($$SELECT definir_operador_ativo(pg_temp.u('A'), pg_temp.u('B'), false, '[TESTE] falha')$$,
  'TS001', 'desativação com a auditoria falhando é recusada');
SELECT pg_temp.confere((SELECT ativo FROM operador_central WHERE usuario_id = pg_temp.u('B')),
  'B continua ativo');
SELECT pg_temp.espera_erro($$SELECT registrar_acesso_central(pg_temp.u('B'))$$,
  'TS001', 'registro de acesso com a auditoria falhando é recusado');
SET LOCAL teste.falhar_auditoria = 'nao';

-- ---------- Sem dado pessoal na auditoria ----------
SELECT pg_temp.confere(
  NOT EXISTS (SELECT 1 FROM auditoria
               WHERE (acao LIKE 'central_%'
                      OR entidade IN ('permissao_central','operador_central','permissao_concessao','permissao_revogacao'))
                 AND (coalesce(antes::text, '') || coalesce(depois::text, '')) LIKE '%@%'),
  'nenhum e-mail na auditoria de permissões e operadores');
