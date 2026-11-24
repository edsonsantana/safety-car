-- 0021 — Ator da Central a partir do sub do token.
--
-- Por quê: as funções da Central recebem o ator como usuario.id (p_ator), mas a API só conhece o
-- sub do token do Keycloak (= usuario.keycloak_sub). O safetycar_central não lê usuario (0014 a
-- 0020, de propósito: e-mail e celular ficam fora do alcance da Central), então a API da Central
-- não tinha como traduzir o sub no id. Ler usuario pelo pool do app misturaria as duas
-- credenciais; esta função resolve só o necessário.
--
-- Regras (aprovadas no plano da API da Central, etapa 1):
--   - devolve o usuario.id SÓ quando o usuário é perfil central, status ativo, excluido_em nulo
--     E operador_central ativo; em qualquer outro caso (sub desconhecido, nulo, tomador, parceiro,
--     pendente, suspenso, bloqueado, excluído, sem cadastro de operador, operador inativo), NULL.
--     A API traduz NULL no mesmo 403 de "sem permissão", sem revelar qual foi o caso;
--   - não devolve e-mail, status nem qualquer outra coluna; não recebe nem devolve texto livre;
--   - não escreve nada (STABLE: o PostgreSQL recusa escrita numa função não volátil);
--   - SECURITY DEFINER com search_path fixo; EXECUTE só para safetycar_central (nem PUBLIC nem
--     safetycar_app: o app poderia sondar, sub a sub, quem é operador ativo).
--   - Sem STRICT, de propósito: com STRICT, o planejador troca ator_central(NULL) por NULL sem
--     chamar a função e a checagem de EXECUTE não acontece (não vaza nada, mas a recusa ficaria
--     inconsistente). Sem STRICT, sub nulo devolve NULL pela própria consulta.
-- É só identificação: a permissão continua sendo conferida por operador_tem_permissao e, de
-- novo, dentro de cada função de ação.
--
-- Sem código de erro novo.

CREATE FUNCTION ator_central(p_keycloak_sub uuid) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT u.id
    FROM usuario u
    JOIN operador_central o ON o.usuario_id = u.id
   WHERE u.keycloak_sub = p_keycloak_sub
     AND u.perfil = 'central'
     AND u.status = 'ativo'
     AND u.excluido_em IS NULL
     AND o.ativo
$$;

COMMENT ON FUNCTION ator_central(uuid) IS
  'usuario.id do operador ativo da Central com este keycloak_sub; NULL em qualquer outro caso. Só identificação (0021).';

-- ---------------------------------------------------------------------
-- Privilégios
-- ---------------------------------------------------------------------

REVOKE ALL ON FUNCTION ator_central(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ator_central(uuid) TO safetycar_central;

-- Conferência: só a Central executa; o app não.
DO $$
BEGIN
  IF NOT has_function_privilege('safetycar_central', 'ator_central(uuid)', 'EXECUTE')
     OR has_function_privilege('safetycar_app', 'ator_central(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION '0021: ator_central deveria ser executável só pelo safetycar_central';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) a
              WHERE p.oid = 'ator_central(uuid)'::regprocedure AND a.grantee = 0) THEN
    RAISE EXCEPTION '0021: ator_central não pode ter EXECUTE para PUBLIC';
  END IF;
END $$;
