# Prompt: banco de dados inicial do Safety Car (PostgreSQL + PostGIS)

> Uso: salvar este arquivo em `docs/PROMPT_BANCO_INICIAL.md`, abrir o Claude Code na raiz do projeto, entrar no **modo plano** (Shift+Tab) e pedir: "Leia docs/PROMPT_BANCO_INICIAL.md e siga as instruções. Comece pelo plano."

---

## Contexto

Leia primeiro, nesta ordem: `CLAUDE.md`, `docs/safety_car_modelo_dados_v1.sql` (modelo de referência) e este arquivo. Se houver conflito, **este arquivo prevalece sobre o SQL v1**.

O Safety Car é uma plataforma de assistência rodoviária conectada (guincho, mecânica e serviços correlatos). Este trabalho cria a **base de dados inicial**: identidade, cadastro do tomador do serviço, cadastro do parceiro prestador, base antifraude e a fundação geoespacial. Ainda não há backend nem frontend definidos.

## Terminologia (importante)

- **tomador**: quem solicita o serviço (na v8 do protótipo: Usuário e Motorista).
- **parceiro**: entidade única (empresa ou profissional) com **nome** e **tipificação**. O tipo pode ser guincho, mecânica, chaveiro, seguros etc. Cobre o que na v8 era *provider* (Prestador) e *partner* (parceiro de seguros). Um parceiro pode ter mais de um tipo.
- **central**: operação interna do Safety Car.
- Não existe perfil separado para parceiro de seguros: é um **tipo** de parceiro. No SQL v1 o perfil `seguradora` **deixa de existir**; use `parceiro`. As tabelas específicas de seguros ficam para outra fase.

## Restrições (não negociáveis)

1. **Não escolha nem instale backend, ORM, framework ou biblioteca.** Use apenas migrações em SQL puro, numeradas, executáveis com `psql`.
2. Não instale nada no computador sem pedir confirmação. Se o Docker não estiver disponível, pare e pergunte.
3. Nenhum segredo, senha ou chave no repositório. Use `.env` (ignorado pelo Git) e `.env.example` com valores fictícios.
4. Nenhum dado real. Dados de teste somente fictícios e claramente marcados.
5. Senha, TOTP e códigos de recuperação **não** ficam neste banco (ficam no Keycloak). O banco guarda apenas o vínculo `keycloak_sub`.
6. Nunca armazenar número de cartão: apenas token do processador de pagamento e dados não sensíveis (bandeira, últimos 4 dígitos).
7. CPF e chave Pix são cifrados na aplicação (`bytea`); busca e unicidade por hash (`cpf_hash`, HMAC com chave fora do repositório). Documente isso.
8. Em dúvida de regra de negócio, **pergunte**. Não invente. As decisões pendentes estão no `CLAUDE.md`.

## Processo

1. **Plano primeiro.** Em modo plano, apresente: estrutura de pastas, lista de migrações, decisões de modelagem e perguntas. Aguarde minha aprovação.
2. Implemente **uma migração por vez**, com commit pequeno em português descrevendo o porquê.
3. Ao final de cada migração, rode do zero (banco vazio) e mostre o resultado.

## Entregas

### 1. Ambiente local
- `docker-compose.yml` com PostgreSQL 16 e PostGIS (imagem `postgis/postgis`; confirme a tag exata antes de fixar), volume nomeado, *healthcheck* e variáveis vindas do `.env`.
- `.env.example`.
- Dois papéis no banco: `safetycar_migrator` (executa migrações) e `safetycar_app` (privilégio mínimo, sem superusuário, sem DDL).

### 2. Migrações (`db/migrations/`)

| Arquivo | Conteúdo |
|---|---|
| `0001_extensoes.sql` | `postgis`, `citext`, `pgcrypto` |
| `0002_nucleo.sql` | `endereco`, `usuario`, `consentimento`, `verificacao_identidade`, `auditoria` |
| `0003_tomador.sql` | `tomador`, `veiculo`, `contato_emergencia` |
| `0004_parceiro.sql` | `parceiro`, `tipo_parceiro` (catálogo, com carga inicial), `parceiro_tipo` (N:N), `parceiro_membro`, `servico_catalogo` (com carga inicial), `parceiro_servico`, `parceiro_viatura`, `parceiro_documento`, `parceiro_conta_recebimento` |
| `0005_geo.sql` | fundação geoespacial (ver abaixo) |
| `0006_antifraude_base.sql` | `meio_pagamento`, `dispositivo`, `sinal_risco`, `bloqueio` |
| `0007_permissoes.sql` | privilégios do `safetycar_app`; auditoria somente de inserção |

Parta das definições de `docs/safety_car_modelo_dados_v1.sql`, aplicando os ajustes deste arquivo.

### 3. Fundação geoespacial (`0005_geo.sql`)
- Coordenadas em `geography(Point, 4326)`.
- `endereco`: adicionar coluna `localizacao geography(Point, 4326)` (anulável) e índice GiST.
- `parceiro_area_atuacao`: substituir o modelo por UF/município **mais** área geográfica opcional (`centro geography(Point,4326)` + `raio_m integer`, ou `area geography(Polygon,4326)`), com índice GiST. Justifique a escolha no plano.
- `parceiro_posicao_atual`: **uma linha por viatura** (upsert), com `viatura_id`, `localizacao`, `precisao_m`, `velocidade_kmh`, `rumo_graus`, `atualizado_em`. Índice GiST.
- **Sem histórico de posições nesta fase.** O prazo de retenção de GPS depende de decisão de privacidade (LGPD). Registre isso como pendência.
- View `vw_parceiro_posicao_valida`: apenas posições com `atualizado_em` de até **180 segundos** (regra herdada da v8: posição mais antiga não é apresentada como atual), de viaturas ativas e de parceiros com `status_credenciamento = 'aprovado'`.
- Função `parceiros_proximos(lat double precision, lng double precision, raio_m integer, servico text)` usando `ST_DWithin` e ordenando por distância, apenas sobre a view acima. Documente que a distância é **geodésica (linha reta)**, não rota viária.

### 4. Antifraude base (`0006_antifraude_base.sql`)
- `meio_pagamento`: `usuario_id`, `psp`, `token_psp`, `bandeira`, `final_4`, `status`, datas. Nunca o número do cartão.
- `dispositivo`: `usuario_id`, `fingerprint_hash`, primeira e última vez visto, `status`.
- `sinal_risco`: `usuario_id`, `dispositivo_id`, `tipo`, `severidade`, `detalhes jsonb`, `criado_em`.
- `bloqueio`: `tipo` (cpf_hash, dispositivo, celular, cartao_fingerprint, email), `valor_hash`, `motivo`, `criado_por`, `criado_em`, `expira_em`.
- Tabelas de garantia/pré-autorização, taxas, evidências, disputa e repasse **não** entram agora: dependem do chamado (fase seguinte).

### 5. Regras de modelagem
- Nomes em português, `snake_case`; chaves `uuid` (`gen_random_uuid()`); datas `timestamptz`.
- Valores controlados em `text` com `CHECK`.
- Perfil do usuário: `tomador`, `parceiro`, `central`.
- **Tipificação do parceiro:** `tipo_parceiro` com `codigo`, `nome`, `exige_viatura`, `exige_registro_susep` e `ativo`. Carga inicial: `guincho`, `mecanica`, `chaveiro`, `seguros` (proponha outros no plano, sem criar por conta própria). Um parceiro pode ter vários tipos em `parceiro_tipo`.
- **Regras por tipo:** viaturas (`parceiro_viatura`) só podem ser cadastradas para parceiro com tipo que exija viatura; parceiro do tipo `seguros` exige documento de registro Susep (acrescente `registro_susep` aos tipos de `parceiro_documento`). Implemente por *trigger* ou restrição e documente. Os serviços de socorro (`parceiro_servico`) valem apenas para os tipos de assistência; não modele produtos de seguro agora.
- `parceiro_area_atuacao` e `parceiros_proximos` consideram apenas parceiros de tipos de assistência rodoviária.
- Placa no padrão antigo e Mercosul; telefones em E.164; CEP com 8 dígitos.
- Um usuário pertence a, no máximo, um parceiro.
- `parceiro`: pessoa jurídica ou MEI exige CNPJ; pessoa física exige `cpf_hash`.
- `auditoria`: somente inserção. Garanta isso por privilégio **e** por *trigger* que bloqueia `UPDATE` e `DELETE`.
- Mantenha `atualizado_em` por *trigger* genérico.
- Índices apenas onde houver consulta prevista; justifique no dicionário.

### 6. Testes (`db/tests/`)
Scripts SQL que falhem de forma clara. Cubra:
- restrições de placa, CEP, telefone e CNPJ;
- regra pessoa física/jurídica do parceiro;
- regras por tipo de parceiro (viatura só para tipo que exige; tipo `seguros` exige registro Susep);
- unicidade de `keycloak_sub`, e-mail, celular e `cpf_hash`;
- bloqueio de `UPDATE`/`DELETE` em `auditoria`;
- `parceiros_proximos` com 3 a 5 parceiros fictícios (um fora do raio, um com posição velha, um não aprovado, um de outro serviço);
- permissões: o `safetycar_app` não consegue criar tabela nem apagar auditoria.

### 7. Documentação
- `docs/BANCO_DE_DADOS.md`: diagrama ER em Mermaid, dicionário de dados (tabela, coluna, tipo, finalidade, dado pessoal sim/não), decisões de modelagem, o que ficou de fora e por quê, e como subir, migrar e testar do zero.
- Seção curta no `README.md` com os comandos para rodar localmente.
- Atualize o `CLAUDE.md` com o estado do banco, **sem** alterar a seção de decisões pendentes.

## Critérios de aceite
1. `docker compose up` sobe o banco saudável.
2. As migrações rodam do zero, sem erro, e podem ser reaplicadas em um banco novo.
3. Todos os testes passam e a saída é mostrada.
4. Nenhum segredo no Git (`git status` e `git log` limpos disso).
5. Documentação completa e coerente com o código.

## Fora do escopo desta fase
Chamados, rastreamento com histórico, chat, avaliações, pagamentos, repasses, seguros, roteamento/ETA e integração com Waze ou Google Maps.

## Pendências que você deve registrar (não decidir)
- Retenção de histórico de GPS e base legal.
- Motor de rotas/ETA (serviço externo ou pgRouting com malha OSM).
- Stack de backend e frontend.
- Valores de carência, taxas e níveis de verificação por serviço.
