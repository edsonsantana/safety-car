-- 0003 — Tomador do serviço: cadastro, veículos e contatos de emergência.
--
-- CPF: cifrado pela aplicação (cpf_cifrado) e buscado/único por cpf_hash
-- (HMAC-SHA256 dos 11 dígitos, chave fora do repositório). Ambos presentes ou ambos nulos:
-- a decisão "CPF no cadastro ou no nível 2" está pendente, por isso o CPF é opcional aqui.

CREATE TABLE tomador (
  usuario_id        uuid PRIMARY KEY REFERENCES usuario(id),
  nome_completo     text NOT NULL,
  nome_social       text,
  cpf_cifrado       bytea,
  cpf_hash          dom_hmac UNIQUE,
  data_nascimento   date,
  endereco_id       uuid REFERENCES endereco(id),
  -- 1 = e-mail + 2FA; 2 = celular e CPF validados; 3 = documento com foto
  nivel_verificacao smallint NOT NULL DEFAULT 1 CHECK (nivel_verificacao BETWEEN 1 AND 3),
  criado_em         timestamptz NOT NULL DEFAULT now(),
  atualizado_em     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_tomador_cpf_par CHECK ((cpf_cifrado IS NULL) = (cpf_hash IS NULL))
);
CREATE TRIGGER tg_tomador_atualizado_em BEFORE UPDATE ON tomador
  FOR EACH ROW EXECUTE FUNCTION definir_atualizado_em();
CREATE TRIGGER tg_tomador_perfil BEFORE INSERT OR UPDATE OF usuario_id ON tomador
  FOR EACH ROW EXECUTE FUNCTION exige_perfil('tomador', 'usuario_id');

CREATE TABLE veiculo (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tomador_id     uuid NOT NULL REFERENCES tomador(usuario_id),
  placa          dom_placa NOT NULL,
  apelido        text,
  marca          text NOT NULL,
  modelo         text NOT NULL,
  ano_fabricacao smallint,
  ano_modelo     smallint,
  cor            text,
  categoria      text NOT NULL
                 CHECK (categoria IN ('passeio','utilitario','moto','van','caminhao','onibus')),
  ativo          boolean NOT NULL DEFAULT true,
  criado_em      timestamptz NOT NULL DEFAULT now(),
  atualizado_em  timestamptz NOT NULL DEFAULT now(),
  -- Também serve de índice para "veículos do tomador X".
  CONSTRAINT uq_veiculo_tomador_placa UNIQUE (tomador_id, placa)
);
CREATE TRIGGER tg_veiculo_atualizado_em BEFORE UPDATE ON veiculo
  FOR EACH ROW EXECUTE FUNCTION definir_atualizado_em();

CREATE TABLE contato_emergencia (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tomador_id    uuid NOT NULL REFERENCES tomador(usuario_id),
  nome          text NOT NULL,
  celular_e164  dom_e164 NOT NULL,
  parentesco    text,
  criado_em     timestamptz NOT NULL DEFAULT now(),
  atualizado_em timestamptz NOT NULL DEFAULT now()
);
-- Consulta prevista: "contatos de emergência do tomador X" (durante um socorro)
CREATE INDEX ix_contato_emergencia_tomador ON contato_emergencia (tomador_id);
CREATE TRIGGER tg_contato_emergencia_atualizado_em BEFORE UPDATE ON contato_emergencia
  FOR EACH ROW EXECUTE FUNCTION definir_atualizado_em();
