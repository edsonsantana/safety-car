# Central: permissões, tarifas e parâmetros (desenho aprovado em 23/11/2026)

Desenho aprovado por Edson e pelo Adailton. Os nomes de tabelas e colunas abaixo são **ilustrativos**: o que já existir nas migrações (em especial 0014 e 0015) **prevalece**, e o desenho se concilia com isso. Fonte visual: Protótipo 5 do canvas e o protótipo navegável da Central.

## Decisões fechadas

- **Reajuste de tarifa**: o operador solicita informando só o **percentual** (positivo ou negativo). Aprova outro operador com a permissão de aprovador. O valor novo é calculado **na aprovação**, sobre a tarifa vigente naquele momento:
  `valor_novo = round(valor_base * (1 + percentual / 100), 2)`, em `numeric` (meio centavo ou mais sobe).
- **Início imediato**, na hora da aprovação, nunca no passado. Sem data de vigência e sem parâmetro de antecedência.
- **Sempre 1 aprovador**, diferente de quem pediu. Sem parâmetro de número de aprovadores nesta versão.
- **Chamado em andamento mantém o preço da hora do pedido.** A tabela de chamados ainda não existe: ao criá-la, ela deverá guardar a referência ao valor de tarifa vigente e o valor copiado.
- **2FA vive no Keycloak.** O banco não valida 2FA. A API exigirá OTP na sessão para ações sensíveis (fora deste escopo).
- Valores de tarifa e regras de negócio ficam em **tabelas de parâmetros**, nunca em código.
- O limite de variação do reajuste (padrão 20%) é **parâmetro editável**, não número fixo.

## Modelo proposto

| Tabela | Finalidade | Regras principais |
| --- | --- | --- |
| `permissao_central` | Catálogo fixo: analisar_cadastros, solicitar_tarifa, aprovar_tarifa (sensível), administrar_permissoes (sensível), administrar_parametros (sensível) | Carga inicial por migração |
| `concessao_permissao` | Quem tem cada permissão, com histórico: operador, permissão, concedida_por, concedida_em, motivo, revogada_por, revogada_em, motivo_revogacao | Uma concessão ativa por operador e permissão. Ninguém concede a si mesmo (exceção: o script do primeiro administrador). Não se revoga o último titular de administrar_permissoes. Nunca apagar linha |
| `tarifa` | Serviço × região, com unidade (fixo ou por km) | Chave única em serviço + região. Regiões e serviços como carga inicial ajustável: Norte, Nordeste, Centro-Oeste, Sudeste, Sul |
| `tarifa_valor` | Histórico de valores: tarifa, valor `numeric(12,2)`, vigente_de, vigente_ate, reajuste de origem | Valor nunca é alterado: reajuste fecha o anterior e insere o novo. Sem sobreposição de períodos (restrição de exclusão por tarifa). Só um valor com vigente_ate vazio por tarifa |
| `reajuste_tarifa` | Pedido e decisão: tarifa, percentual, justificativa, motivo_excecao, limite_na_criacao, solicitado_por, solicitado_em, status, decidido_por, decidido_em, motivo_decisao, valor_base, valor_novo | Status: aguardando, aprovado, recusado, cancelado. decidido_por diferente de solicitado_por. valor_base e valor_novo só na aprovação. Um pedido aguardando por tarifa. Acima do limite exige motivo_excecao. Decidido = imutável |
| `parametro` | Catálogo: chave, descrição, tipo, mínimo, máximo, sensível | Iniciais: limite_variacao_reajuste (padrão 20, percentual, mín. 1, máx. 100, sensível) e alerta_documento_dias (padrão 30, comum) |
| `parametro_valor` | Histórico: valor, vigente_de, vigente_ate, referencia_alinhamento, motivo, alterado_por, aprovado_por | Mesma técnica de `tarifa_valor` |
| `parametro_alteracao` | Pedido de mudança de parâmetro sensível | Mesmo fluxo e mesmas travas do reajuste. Parâmetro comum é aplicado direto, com a permissão administrar_parametros |

## Regras que o banco garante

- Quem pede não decide o próprio pedido (reajuste e parâmetro sensível).
- Só decide quem tem a permissão ativa naquele instante.
- Transições válidas: aguardando para aprovado, recusado ou cancelado. Depois disso, imutável.
- Duas aprovações simultâneas não geram dois valores: a decisão trava a linha do pedido e a da tarifa antes de calcular.
- Escrita só por funções do banco (conceder, revogar, solicitar, decidir, cancelar, alterar parâmetro). `safetycar_app` não tem INSERT, UPDATE nem DELETE direto nas tabelas novas; só EXECUTE nas funções, e leitura por visões somente leitura (por exemplo, operadores com suas permissões).
- Cada função grava a auditoria **na mesma transação**: se a auditoria falhar, nada é gravado.
- Operador suspenso ou inativo perde o efeito das permissões na próxima chamada, sem apagar histórico.

## Auditoria

Seguir o padrão atual: só inserção, `papel_bd = session_user`, sem e-mail, nome nem CPF; apenas identificadores internos e valores antes e depois.

Eventos novos: permissao_concedida, permissao_revogada, reajuste_solicitado, reajuste_aprovado, reajuste_recusado, reajuste_cancelado, parametro_solicitado, parametro_decidido, parametro_alterado e acesso_central (uma vez por início de sessão, para "último acesso").

## Testes (um script por migração, em banco descartável)

- Quem pede não decide; sem a permissão não decide; permissão revogada não decide; operador suspenso não decide.
- Arredondamento: 100,05 com +10% dá 110,06; 0,5 sobe e abaixo de 0,5 desce; reajuste negativo.
- Percentual acima do limite sem motivo_excecao é recusado; o limite usado é o da criação do pedido.
- Duas aprovações simultâneas (script de concorrência, como os da 0014 e 0015): um valor só, sem sobreposição.
- O valor anterior fecha no mesmo instante em que o novo abre; nada fica no passado.
- Pedido decidido não muda; UPDATE e DELETE diretos falham.
- Não revogar o último titular de administrar_permissoes.
- Ninguém concede permissão a si mesmo, exceto o script do primeiro administrador, que continua funcionando (rodar `testar_primeiro_administrador.sh`).
- Cada operação grava sua auditoria; falha da auditoria desfaz a operação.
- Nenhum e-mail ou dado pessoal na auditoria nem nos dados de teste (`@exemplo.invalid`).

## Ponto em aberto

Falta definir **quem cadastra a primeira tarifa** de cada serviço × região e com qual permissão. O reajuste só atua sobre tarifa existente.

## Fora do escopo

API, frontend, Keycloak, tabela de chamados e importação do SNV.
