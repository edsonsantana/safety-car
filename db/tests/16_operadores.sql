-- 16 — Operadores e permissões da Central (0014), como safetycar_migrator (dono das funções).
-- Usuários FICTÍCIOS: A, B e C de perfil central; T tomador.

INSERT INTO usuario (id, keycloak_sub, email, perfil, status) VALUES
  ('00000000-0000-4000-8000-0000000c0a01', gen_random_uuid(), 'op-a@exemplo.invalid', 'central', 'ativo'),
  ('00000000-0000-4000-8000-0000000c0a02', gen_random_uuid(), 'op-b@exemplo.invalid', 'central', 'ativo'),
  ('00000000-0000-4000-8000-0000000c0a03', gen_random_uuid(), 'op-c@exemplo.invalid', 'central', 'ativo'),
  ('00000000-0000-4000-8000-0000000c0a09', gen_random_uuid(), 'op-t@exemplo.invalid', 'tomador', 'ativo');

CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $f$
  SELECT ('00000000-0000-4000-8000-0000000c0a0' || CASE p WHEN 'A' THEN '1' WHEN 'B' THEN '2' WHEN 'C' THEN '3' ELSE '9' END)::uuid
$f$;

-- ---------- Catálogo ----------
SELECT pg_temp.confere(
  (SELECT array_agg(codigo ORDER BY codigo) = '{aprovar_reajuste_taxa,conceder_permissao}' FROM permissao_central),
  'catálogo com conceder_permissao e aprovar_reajuste_taxa');
SELECT pg_temp.confere(
  (SELECT NOT permite_autoaprovacao FROM permissao_central WHERE codigo = 'aprovar_reajuste_taxa'),
  'aprovar_reajuste_taxa começa sem autoaprovação');
SELECT pg_temp.espera_erro($$UPDATE permissao_central SET permite_autoaprovacao = true WHERE codigo = 'conceder_permissao'$$,
  '23514', 'conceder_permissao nunca admite autoaprovação');
SELECT pg_temp.espera_erro($$SELECT operador_tem_permissao(pg_temp.u('A'), 'aprovar_tudo')$$,
  '22023', 'permissão inexistente na consulta');
SELECT pg_temp.confere(NOT operador_tem_permissao(pg_temp.u('A'), 'conceder_permissao'),
  'ninguém tem permissão por padrão');

-- ---------- Concessão inicial (à mão, pelo migrator) ----------
SELECT pg_temp.espera_erro($$SELECT conceder_permissao_inicial(pg_temp.u('A'), '  ')$$,
  '22023', 'concessão inicial sem motivo é recusada');
SELECT pg_temp.espera_erro($$SELECT conceder_permissao_inicial(pg_temp.u('T'), '[TESTE] tomador')$$,
  'SC001', 'concessão inicial a usuário que não é central é recusada');
SELECT pg_temp.aceita($$SELECT conceder_permissao_inicial(pg_temp.u('A'), '[TESTE] primeiro administrador')$$,
  'concessão inicial de conceder_permissao ao operador A');
SELECT pg_temp.confere(operador_tem_permissao(pg_temp.u('A'), 'conceder_permissao'),
  'A tem conceder_permissao vigente');
SELECT pg_temp.confere(NOT operador_tem_permissao(pg_temp.u('A'), 'aprovar_reajuste_taxa'),
  'concessão inicial não dá outras permissões');
SELECT pg_temp.espera_erro($$SELECT conceder_permissao_inicial(pg_temp.u('B'), '[TESTE] segunda inicial')$$,
  'SC018', 'segunda concessão inicial é recusada enquanto houver detentor');
SELECT pg_temp.espera_erro($$
  INSERT INTO permissao_concessao (operador_id, permissao_codigo, motivo, origem)
  VALUES (pg_temp.u('A'), 'aprovar_reajuste_taxa', '[TESTE]', 'inicial')$$,
  '23514', 'concessão inicial só serve para conceder_permissao');
SELECT pg_temp.confere(
  EXISTS (SELECT 1 FROM auditoria WHERE entidade = 'permissao_concessao' AND acao = 'parametrizacao_insert'
             AND depois ->> 'origem' = 'inicial' AND ator_usuario_id IS NULL AND papel_bd = 'safetycar_migrator'),
  'concessão inicial está na auditoria (papel safetycar_migrator, sem ator)');

-- ---------- Cadastro de operadores ----------
SELECT pg_temp.espera_erro($$SELECT cadastrar_operador(pg_temp.u('B'), pg_temp.u('C'), '[TESTE]')$$,
  'SC016', 'quem não tem conceder_permissao não cadastra operador');
SELECT pg_temp.espera_erro($$SELECT cadastrar_operador(pg_temp.u('A'), pg_temp.u('A'), '[TESTE]')$$,
  'SC017', 'ninguém cadastra a si mesmo');
SELECT pg_temp.espera_erro($$SELECT cadastrar_operador(pg_temp.u('A'), pg_temp.u('T'), '[TESTE]')$$,
  'SC001', 'operador precisa ter perfil central');
SELECT pg_temp.aceita($$SELECT cadastrar_operador(pg_temp.u('A'), pg_temp.u('B'), '[TESTE] entrada na equipe')$$,
  'A cadastra B');
SELECT pg_temp.aceita($$SELECT cadastrar_operador(pg_temp.u('A'), pg_temp.u('C'), '[TESTE] entrada na equipe')$$,
  'A cadastra C');
SELECT pg_temp.confere(
  EXISTS (SELECT 1 FROM auditoria WHERE acao = 'central_cadastrar_operador' AND entidade_id = pg_temp.u('B')
             AND ator_usuario_id = pg_temp.u('A') AND depois ->> 'motivo' = '[TESTE] entrada na equipe')
  AND EXISTS (SELECT 1 FROM auditoria WHERE entidade = 'operador_central' AND acao = 'parametrizacao_insert'
                 AND depois ->> 'usuario_id' = pg_temp.u('B')::text AND ator_usuario_id = pg_temp.u('A')),
  'cadastro do operador na auditoria, com ator e motivo');

-- ---------- Concessão ----------
SELECT pg_temp.espera_erro($$SELECT conceder_permissao(pg_temp.u('A'), pg_temp.u('B'), 'aprovar_reajuste_taxa', '')$$,
  '22023', 'concessão sem motivo é recusada');
SELECT pg_temp.espera_erro($$SELECT conceder_permissao(pg_temp.u('A'), pg_temp.u('A'), 'aprovar_reajuste_taxa', '[TESTE]')$$,
  'SC017', 'ninguém concede permissão a si mesmo');
SELECT pg_temp.espera_erro($$SELECT conceder_permissao(pg_temp.u('B'), pg_temp.u('C'), 'aprovar_reajuste_taxa', '[TESTE]')$$,
  'SC016', 'quem não tem conceder_permissao não concede');
SELECT pg_temp.aceita($$SELECT conceder_permissao(pg_temp.u('A'), pg_temp.u('B'), 'aprovar_reajuste_taxa', '[TESTE] aprovador de taxas')$$,
  'A concede aprovar_reajuste_taxa a B');
SELECT pg_temp.confere(operador_tem_permissao(pg_temp.u('B'), 'aprovar_reajuste_taxa'),
  'B tem aprovar_reajuste_taxa vigente');
SELECT pg_temp.confere(NOT operador_tem_permissao(pg_temp.u('C'), 'aprovar_reajuste_taxa'),
  'C não tem a permissão');
SELECT pg_temp.espera_erro($$SELECT conceder_permissao(pg_temp.u('A'), pg_temp.u('B'), 'aprovar_reajuste_taxa', '[TESTE] de novo')$$,
  'SC018', 'concessão repetida enquanto vigente é recusada');
SELECT pg_temp.espera_erro($$SELECT conceder_permissao(pg_temp.u('A'), pg_temp.u('T'), 'aprovar_reajuste_taxa', '[TESTE]')$$,
  'SC016', 'concessão a quem não é operador é recusada');
SELECT pg_temp.espera_erro($$
  INSERT INTO permissao_concessao (operador_id, permissao_codigo, concedida_por, motivo, origem)
  VALUES (pg_temp.u('A'), 'aprovar_reajuste_taxa', pg_temp.u('A'), '[TESTE] direto', 'operador')$$,
  'SC017', 'autoconcessão recusada também por INSERT direto (regra no trigger)');
SELECT pg_temp.confere(
  EXISTS (SELECT 1 FROM auditoria WHERE entidade = 'permissao_concessao' AND ator_usuario_id = pg_temp.u('A')
             AND depois ->> 'operador_id' = pg_temp.u('B')::text
             AND depois ->> 'motivo' = '[TESTE] aprovador de taxas'),
  'concessão na auditoria com ator, quem recebeu e motivo');

-- ---------- Vigência derivada: permissão, operador e usuário ativos ----------
UPDATE permissao_central SET ativo = false WHERE codigo = 'aprovar_reajuste_taxa';
SELECT pg_temp.confere(NOT operador_tem_permissao(pg_temp.u('B'), 'aprovar_reajuste_taxa'),
  'permissão inativa no catálogo não vale');
SELECT pg_temp.espera_erro($$SELECT conceder_permissao(pg_temp.u('A'), pg_temp.u('C'), 'aprovar_reajuste_taxa', '[TESTE]')$$,
  '22023', 'permissão inativa não é concedida');
UPDATE permissao_central SET ativo = true WHERE codigo = 'aprovar_reajuste_taxa';

SELECT pg_temp.espera_erro($$SELECT definir_operador_ativo(pg_temp.u('A'), pg_temp.u('A'), false, '[TESTE]')$$,
  'SC017', 'ninguém desativa a si mesmo');
SELECT pg_temp.aceita($$SELECT definir_operador_ativo(pg_temp.u('A'), pg_temp.u('B'), false, '[TESTE] afastamento')$$,
  'A desativa B');
SELECT pg_temp.confere(NOT operador_tem_permissao(pg_temp.u('B'), 'aprovar_reajuste_taxa'),
  'operador inativo perde a permissão');
SELECT pg_temp.confere(
  EXISTS (SELECT 1 FROM vw_permissao_vigente WHERE operador_id = pg_temp.u('B') AND NOT efetiva),
  'a concessão continua no histórico, sem revogação, mas não efetiva');
SELECT pg_temp.aceita($$SELECT definir_operador_ativo(pg_temp.u('A'), pg_temp.u('B'), true, '[TESTE] retorno')$$,
  'A reativa B');
SELECT pg_temp.confere(operador_tem_permissao(pg_temp.u('B'), 'aprovar_reajuste_taxa'),
  'reativado, B volta a ter a permissão (sem nova concessão)');
UPDATE usuario SET status = 'suspenso' WHERE id = pg_temp.u('B');
SELECT pg_temp.confere(NOT operador_tem_permissao(pg_temp.u('B'), 'aprovar_reajuste_taxa'),
  'usuário suspenso perde a permissão');
UPDATE usuario SET status = 'ativo' WHERE id = pg_temp.u('B');

-- ---------- Revogação ----------
SELECT pg_temp.espera_erro($$SELECT revogar_permissao(pg_temp.u('C'), pg_temp.u('B'), 'aprovar_reajuste_taxa', '[TESTE]')$$,
  'SC016', 'quem não tem conceder_permissao não revoga a permissão de outro');
SELECT pg_temp.aceita($$SELECT revogar_permissao(pg_temp.u('A'), pg_temp.u('B'), 'aprovar_reajuste_taxa', '[TESTE] troca de função')$$,
  'A revoga a permissão de B');
SELECT pg_temp.confere(NOT operador_tem_permissao(pg_temp.u('B'), 'aprovar_reajuste_taxa'),
  'B não tem mais a permissão');
SELECT pg_temp.confere(
  (SELECT r.revogada_por = pg_temp.u('A') AND r.motivo = '[TESTE] troca de função' AND r.revogada_em IS NOT NULL
     FROM permissao_revogacao r JOIN permissao_concessao c ON c.id = r.concessao_id
    WHERE c.operador_id = pg_temp.u('B')),
  'revogação registra quem revogou, quando e por quê');
SELECT pg_temp.espera_erro($$SELECT revogar_permissao(pg_temp.u('A'), pg_temp.u('B'), 'aprovar_reajuste_taxa', '[TESTE]')$$,
  'SC018', 'revogar o que não está vigente é recusado');
SELECT pg_temp.aceita($$SELECT conceder_permissao(pg_temp.u('A'), pg_temp.u('B'), 'aprovar_reajuste_taxa', '[TESTE] retorno à função')$$,
  'depois de revogada, a permissão pode ser concedida de novo (nova linha)');
SELECT pg_temp.confere(
  (SELECT count(*) = 2 FROM permissao_concessao WHERE operador_id = pg_temp.u('B') AND permissao_codigo = 'aprovar_reajuste_taxa'),
  'histórico guarda as duas concessões');

SELECT pg_temp.aceita($$SELECT conceder_permissao(pg_temp.u('A'), pg_temp.u('C'), 'aprovar_reajuste_taxa', '[TESTE]')$$,
  'A concede a C');
SELECT pg_temp.aceita($$SELECT revogar_permissao(pg_temp.u('C'), pg_temp.u('C'), 'aprovar_reajuste_taxa', '[TESTE] abdica')$$,
  'C revoga a própria permissão (só reduz poder)');

-- ---------- Ator: restaurado ao fim de cada função (chamada aninhada) ----------
SET LOCAL safetycar.ator_usuario_id = '00000000-0000-4000-8000-0000000c0a03';   -- ator "de fora" = C
SELECT definir_operador_ativo(pg_temp.u('A'), pg_temp.u('C'), true, '[TESTE] chamada interna');
SELECT pg_temp.confere(current_setting('safetycar.ator_usuario_id', true) = pg_temp.u('C')::text,
  'depois da função, o ator da transação volta a ser o de fora (C), não fica vazio nem vira A');
SELECT pg_temp.confere(
  EXISTS (SELECT 1 FROM auditoria WHERE acao = 'central_ativar_operador' AND entidade_id = pg_temp.u('C')
             AND ator_usuario_id = pg_temp.u('A') AND depois ->> 'motivo' = '[TESTE] chamada interna'),
  'dentro da função, a auditoria registra o ator da função (A)');

-- Chamada aninhada de verdade: uma função de fora define o próprio ator, chama a de ação e,
-- depois dela, grava auditoria com o ator corrente.
CREATE FUNCTION pg_temp.acao_de_fora() RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM set_config('safetycar.ator_usuario_id', '00000000-0000-4000-8000-0000000c0a02', true);  -- B
  PERFORM definir_operador_ativo('00000000-0000-4000-8000-0000000c0a01'::uuid,
                                 '00000000-0000-4000-8000-0000000c0a03'::uuid, true, '[TESTE] aninhada');
  INSERT INTO auditoria (ator_usuario_id, acao, entidade)
  VALUES (nullif(current_setting('safetycar.ator_usuario_id', true), '')::uuid, 'teste_acao_de_fora', 'teste');
  RETURN current_setting('safetycar.ator_usuario_id', true);
END $f$;
SELECT pg_temp.confere(pg_temp.acao_de_fora() = pg_temp.u('B')::text,
  'chamada aninhada não apaga o ator da função de fora (B)');
SELECT pg_temp.confere(
  (SELECT ator_usuario_id = pg_temp.u('B') FROM auditoria WHERE acao = 'teste_acao_de_fora'),
  'o que a função de fora grava depois continua com o ator dela (B)');
RESET safetycar.ator_usuario_id;

-- ---------- Somente inserção e vínculos ----------
SELECT pg_temp.espera_erro($$UPDATE permissao_concessao SET motivo = 'x'$$,
  'SC010', 'concessão não é alterada');
SELECT pg_temp.espera_erro($$DELETE FROM permissao_revogacao$$,
  'SC010', 'revogação não é apagada');
SELECT pg_temp.espera_erro($$DELETE FROM operador_central WHERE usuario_id = pg_temp.u('C')$$,
  'SC010', 'operador não é excluído (só desativado)');
SELECT pg_temp.espera_erro($$TRUNCATE permissao_concessao CASCADE$$,
  'SC010', 'TRUNCATE no histórico de concessões é bloqueado');
SELECT pg_temp.espera_erro($$UPDATE usuario SET perfil = 'tomador' WHERE id = pg_temp.u('C')$$,
  'SC001', 'operador da Central não troca de perfil');

-- ---------- Recuperação: revogação manual e nova concessão inicial ----------
SELECT pg_temp.aceita($$SELECT revogar_permissao_manual(pg_temp.u('A'), 'conceder_permissao', '[TESTE] emergência')$$,
  'revogação manual (emergência) pelo migrator');
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM vw_permissao_vigente WHERE permissao_codigo = 'conceder_permissao'),
  'ninguém mais tem conceder_permissao');
SELECT pg_temp.aceita($$SELECT conceder_permissao_inicial(pg_temp.u('B'), '[TESTE] recuperação')$$,
  'sem detentor, a concessão inicial volta a ser possível (recuperação)');
SELECT pg_temp.confere(
  EXISTS (SELECT 1 FROM auditoria WHERE entidade = 'permissao_revogacao' AND depois ->> 'origem' = 'manual'
             AND papel_bd = 'safetycar_migrator'),
  'revogação manual está na auditoria');
