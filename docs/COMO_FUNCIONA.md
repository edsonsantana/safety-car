# Como funciona o Safety Car

Este documento explica o Safety Car **como produto**: quem usa, o que cada um faz e quais regras valem. É técnico-funcional: descreve comportamento, sem projeções nem prazos. Os detalhes de implementação (tabelas, colunas, códigos de erro) ficam no [`BANCO_DE_DADOS.md`](BANCO_DE_DADOS.md).

**Como ler as marcações.** Em cada seção, os itens estão separados assim:

- **Decidido:** regra fechada. Parte já está construída e testada no banco.
- **Proposta:** já há um texto ou uma carga inicial, mas falta confirmar.
- **A definir:** decisão em aberto. A estrutura pode já existir, mas o valor ou a regra não foi escolhido.
- **Previsto:** comportamento planejado para uma fase seguinte, ainda não construído.

Os valores "a definir" nunca são tratados como zero: o sistema recusa usá-los até que sejam definidos.

## Sumário
1. [O que é o Safety Car](#1-o-que-é-o-safety-car)
2. [Os três papéis](#2-os-três-papéis)
3. [O fluxo de um chamado](#3-o-fluxo-de-um-chamado)
4. [A garantia antifraude](#4-a-garantia-antifraude)
5. [Níveis de verificação](#5-níveis-de-verificação)
6. [Segurança](#6-segurança)
7. [Taxas e reajuste governado](#7-taxas-e-reajuste-governado)
8. [Estado atual](#8-estado-atual)
9. [Mapa dos documentos](#9-mapa-dos-documentos)

---

## 1. O que é o Safety Car

O Safety Car é uma plataforma de assistência rodoviária conectada: guincho, mecânica, chaveiro e serviços correlatos, como bateria, pneu e combustível. Quem precisa de socorro (o **tomador**) faz o pedido pelo aplicativo. Um prestador credenciado (o **parceiro**) aceita e compartilha a posição. A operação interna (a **Central**) acompanha o atendimento e cuida do credenciamento, da antifraude e das regras de preço. O projeto é feito em parceria com o Adailton.

## 2. Os três papéis

Cada usuário tem um único perfil: tomador, parceiro ou Central.

### Tomador
Quem solicita o serviço.

**Decidido**
- O CPF é obrigatório **no cadastro**.
- A verificação do celular é obrigatória. Em que nível ela passa a ser exigida é proposta (nível 1, ver [seção 5](#5-níveis-de-verificação)).
- O tomador cadastra os seus veículos e os seus contatos de emergência.
- O tomador dá ou revoga consentimentos por finalidade (termos de uso, política de privacidade, compartilhamento de localização, contato comercial e compartilhamento com parceiro de seguros). Cada aceite fica registrado, com o histórico.
- O nível de verificação define quais serviços o tomador pode pedir (ver [seção 5](#5-níveis-de-verificação)).

**Proposta**
- 2FA incentivado, mas não obrigatório, para o tomador (ver [seção 6](#6-segurança)).

**A definir**
- Canal de verificação do celular: SMS ou WhatsApp.

### Parceiro
Empresa ou profissional que presta o serviço. É uma entidade única, com nome e **um ou mais tipos**.

**Decidido**
- Tipos iniciais e regras de cada um:

  | Tipo | Viatura | Presta socorro | Exigência extra na aprovação |
  |---|---|---|---|
  | Guincho | obrigatória | sim | ao menos uma viatura ativa |
  | Mecânica | permitida | sim | — |
  | Chaveiro | permitida | sim | — |
  | Seguros | não se aplica | não | registro Susep aprovado |

- O parceiro pode ser empresa (PJ), MEI ou pessoa física. Para PJ e MEI, o CPF do responsável legal é exigido na aprovação do credenciamento. O CNPJ é aceito no formato numérico e no alfanumérico.
- **Credenciamento:** o cadastro começa em rascunho, passa por análise e pode ter pendências. Termina aprovado ou reprovado, e o parceiro pode depois ser suspenso ou descredenciado. As exigências do tipo (viatura, Susep, CPF do responsável) só são cobradas no momento da aprovação, para que o rascunho possa ser preenchido aos poucos.
- Os parceiros que prestam socorro declaram:
  - os serviços que oferecem;
  - a área de atuação (UF, município e, se quiserem, um centro com raio, como "atendo até 40 km da base");
  - as viaturas.
- A equipe do parceiro tem papéis (proprietário, administrador, despachante e motorista-operador). Cada usuário pertence a, no máximo, um parceiro.
- Os documentos (contrato social, CNH, CRLV, seguro, alvará, registro Susep etc.) são revisados pela Central.
- O parceiro cadastra uma conta de recebimento por chave Pix, guardada cifrada e prevista para os repasses.

**Proposta**
- 2FA obrigatório para o parceiro (a confirmar).
- Novos tipos sugeridos, **ainda não criados**: borracharia, autoelétrica e transporte do motorista quando o veículo é guinchado.

**A definir**
- O que acontece com um parceiro aprovado quando um documento obrigatório vence ou é rejeitado depois da aprovação.
- Se a busca por parceiros deve também exigir que o local do pedido esteja na área de atuação declarada.
- Quais serviços cada tipo de parceiro presta (ainda não há vínculo formal entre tipo e serviço).
- Escopo do módulo de seguros. O tipo "seguros" existe, mas produtos e apólices ainda não.

### Central
A operação interna do Safety Car.

**Decidido**
- A Central analisa credenciamentos e documentos, cria bloqueios antifraude e concede ajustes manuais de nível, sempre com motivo registrado.
- A Central solicita e aprova reajustes de taxa (ver [seção 7](#7-taxas-e-reajuste-governado)).
- **Não existe um "administrador" fixo.** Cada ação sensível exige uma permissão específica, dada a uma pessoa e registrada num histórico. Hoje existem duas: "conceder permissão" e "aprovar reajuste de taxa". Novas permissões só entram por mudança revisada no repositório.
- Ninguém concede permissão a si mesmo, e quem solicita não aprova o próprio pedido.
- Um operador desativado perde todas as permissões, e o histórico continua intacto.

**Proposta**
- 2FA obrigatório para a Central (a confirmar).

**A definir**
- Quem será o primeiro administrador de permissões.
- As telas da Central. Os protótipos estão no canvas; no código há só o layout de painel.

## 3. O fluxo de um chamado

> **Previsto.** O chamado é a próxima fase e ainda não foi construído. Os passos abaixo são as etapas que os documentos já sustentam. **A ordem exata entre eles está a definir** (por exemplo, se a garantia vem antes ou depois da escolha do parceiro).

Etapas previstas:

1. **Pedido.** O tomador escolhe o serviço e informa o local do socorro.
2. **Conferências.** O sistema confere se o nível de verificação do tomador alcança o mínimo do serviço e se algum dado do tomador está na lista de bloqueio.
3. **Garantia.** O tomador deixa a garantia por pré-autorização no cartão ou por Pix pré-pago (ver [seção 4](#4-a-garantia-antifraude)).
4. **Busca de parceiros.**
   - O sistema procura viaturas próximas de parceiros aprovados que oferecem o serviço.
   - Usa só posições de até 180 segundos: posição mais antiga não é apresentada como atual.
   - A distância é em linha reta, e não pela rota nas ruas.
5. **Aceite e acompanhamento.** O parceiro aceita e compartilha a posição, e a Central acompanha o atendimento. Waze e Google Maps servem apenas para a navegação do motorista, fora do aplicativo.
6. **Atendimento e pagamento.** O serviço é concluído, cobrado e repassado ao parceiro.

**Decidido**
- O preço é registrado na hora do pedido. O chamado guarda quais regras de taxa foram usadas e os valores, e um chamado em andamento mantém esse preço mesmo que haja reajuste depois.
- A posição com mais de 180 segundos não é apresentada como atual.
- A busca já existe no banco: distância geodésica, só viaturas ativas, só parceiros aprovados de tipos que prestam socorro.
- Ambulância: o fluxo é **apenas fictício**. Em urgência, os números são 192 (SAMU) e 193 (Bombeiros).

**A definir**
- A ordem dos passos.
- Regras de cancelamento e de não comparecimento (os componentes de taxa existem, mas sem valor nem regra de aplicação).
- Evidências do atendimento, disputa, chat e avaliações.
- Pagamento efetivo e repasse (dependem do processador de pagamento).
- Como se calcula a estimativa do serviço.
- Tempo de chegada e motor de rotas.
- Se haverá histórico de posições, por quanto tempo e com qual base legal. Hoje só existe a posição atual de cada viatura.

## 4. A garantia antifraude

No chamado, o tomador deixa uma garantia, que faz parte da proteção antifraude. O momento exato em que ela é cobrada depende da ordem do fluxo, que está a definir (ver [seção 3](#3-o-fluxo-de-um-chamado)).

**Decidido**
- Duas modalidades: **pré-autorização no cartão** e **Pix pré-pago**.
- O valor da garantia depende do serviço, do nível de verificação do tomador e da modalidade. Pode ser um valor fixo ou um percentual da estimativa do serviço.
- O nível 0 (cadastro incompleto) não tem garantia, porque não pede serviço.
- **O número do cartão nunca é guardado:** só o token do processador de pagamento, a bandeira e os quatro últimos dígitos.
- A antifraude também conta com:
  - **lista de bloqueio** por CPF, e-mail, celular, aparelho e cartão (guardados como código de verificação, não em texto);
  - **sinais de risco**, como várias contas no mesmo aparelho, o mesmo cartão em várias contas, cartão recusado ou localização inconsistente;
  - **registro dos aparelhos** usados por cada conta.
- Garantia "a definir" nunca vale como zero: sem valor definido, não há garantia calculada.

**Proposta**
- A lista inicial de tipos de sinal de risco está em revisão.

**A definir**
- **Valores** da garantia, por serviço e nível, e se cada caso é fixo ou percentual (toda a carga inicial está "a definir").
- Processador de pagamento.
- Base do percentual: como se calcula a estimativa do serviço.

## 5. Níveis de verificação

O nível de verificação mede o quanto um cadastro foi comprovado. Ele vai de **0 a 3** e vale para tomadores e parceiros.

**Decidido**
- **Todo cadastro nasce no nível 0 ("cadastro incompleto")**, que não libera nenhum serviço.
- Cada nível exige os requisitos dele e os de todos os níveis abaixo.
- O nível só muda por um registro num histórico que não se apaga, com a origem: cálculo automático, ajuste manual da Central (com motivo obrigatório), importação do protótipo anterior ou mudança feita pela equipe técnica. O nível pode subir ou descer, inclusive de volta ao 0.
- Cada serviço terá um **nível mínimo por perfil**. O nível 0 nunca cumpre o mínimo de nenhum serviço.
- Nível mínimo "a definir" nunca vale como liberado: o sistema recusa o serviço até que o mínimo seja definido.

**Proposta** (carregada no banco como proposta, a confirmar):

| Nível | Tomador | Parceiro |
|---|---|---|
| 1 | e-mail e celular verificados | e-mail e celular verificados e 2FA ativado |
| 2 | documento com foto e selfie conferidos com o CPF | documento e selfie do responsável |
| 3 | meio de pagamento válido para a garantia | documentos do tipo e conta de recebimento aprovados |

**A definir**
- Os requisitos acima (são proposta).
- O nível mínimo de cada serviço, para tomador e para parceiro.
- Se o banco também deve conferir que os requisitos foram cumpridos antes de um aumento automático. Hoje essa conferência é da aplicação.

## 6. Segurança

**Decidido**
- **2FA por aplicativo autenticador (TOTP)**, compatível com Google Authenticator e Microsoft Authenticator.
- **Login:** senha, 2FA e códigos de recuperação ficam num serviço de identidade separado (Keycloak). O banco do Safety Car guarda só o vínculo com a conta. O Keycloak está decidido, com a confirmação do Adailton pendente.
- **Dados sensíveis:** CPF e chave Pix são cifrados pela aplicação antes de chegar ao banco. A busca e a checagem de duplicidade usam um código de verificação calculado com uma chave guardada fora do repositório.
- **Separação de acessos no banco:**
  - o aplicativo usa uma credencial que lê e grava dados, mas não muda a estrutura do banco nem as regras de preço;
  - as ações sensíveis da Central usam uma **credencial de banco separada para a Central**, e o banco confere se o ator informado tem a permissão e registra quem agiu.

  Assim, uma falha no aplicativo público não consegue conceder permissão nem aprovar reajuste. Isso já está garantido e testado no banco. Os detalhes estão no [`BANCO_DE_DADOS.md`](BANCO_DE_DADOS.md#ambiente-e-papéis).

  **Ainda não construído:** o backend da Central. Ele deverá obter o ator do login, nunca de um dado enviado no pedido. Mesmo assim, uma falha nesse próprio backend ainda poderia declarar um ator falso, porque é ele quem informa o ator ao banco.
- **Aprovações da Central:** feitas por quem tem a permissão vigente, nunca pelo próprio solicitante e nunca em benefício próprio (ver [seção 2](#central)).
- **Auditoria somente de inserção:** as mudanças de regras, permissões e níveis ficam registradas, com quem fez, quando e o antes e o depois. Esse registro não pode ser alterado nem apagado pelo aplicativo. Os históricos de nível, de permissões e de reajustes também são somente de inserção.
- **Sem segredos no repositório:** senhas e chaves ficam em variáveis de ambiente, fora do Git. Não há conta nem senha de demonstração em ambiente compartilhado.
- **Privacidade nos registros:** o log da API não grava conteúdo das requisições, endereço IP, token nem identificadores pessoais.
- **Regras de produto:**
  - a posição com mais de 180 segundos não é apresentada como atual;
  - **nunca se sugere a um usuário em socorro que uma apólice nova cobre o evento que já ocorreu**;
  - ambulância só em fluxo fictício, com orientação para 192 e 193.

**Proposta**
- 2FA incentivado para o tomador e obrigatório para parceiro e Central. Ainda não está configurado como obrigatório no serviço de identidade.
- Política de senha com no mínimo 12 caracteres, sem repetir o e-mail.
- Bloqueio temporário do login, com espera crescente, depois de várias senhas erradas (hoje só na configuração de desenvolvimento).

**A definir**
- Onde ficam as chaves de cifragem em produção e como é feita a troca periódica delas.
- A configuração de produção do serviço de identidade. A atual é só de desenvolvimento.

## 7. Taxas e reajuste governado

### Parametrização

**Decidido**
- O preço é montado por **componentes**: base, por km, mínimo, cancelamento, não comparecimento e comissão da plataforma.
- Cada regra vale para um tipo de parceiro, um serviço e uma UF. A regra nacional é usada nas UFs sem regra própria.
- Os valores são inteiros (centavos, centavos por km ou centésimos de ponto percentual), sem arredondamento de ponto flutuante.
- **Vigência:** cada regra tem início e, opcionalmente, fim, e duas regras do mesmo escopo nunca valem ao mesmo tempo.
- **Mudar um valor cria uma nova versão:** a regra antiga é encerrada e continua consultável por data. Não se apaga regra nem se altera o passado.
- **O aplicativo só lê as regras.** Alterações são feitas por mudança revisada no repositório e ficam na auditoria. A única exceção é o reajuste em lote, abaixo.
- Taxa "a definir" nunca vale como zero.

**Padrão provisório**
- A distância cobrada por km é, por enquanto, **em linha reta**. É a única com cálculo no banco hoje.

**A definir**
- **Todos os valores.** A carga inicial está inteira "a definir".
- A base da distância cobrada por km: linha reta, rodoviária por base pública (SNV ou OSM) ou provedor externo. Depende da licença do SNV e dos termos do provedor.
- Se o cancelamento será cobrado em valor fixo ou em percentual.
- O cálculo do preço do chamado (fase do chamado).

### Reajuste em lote

Serve para reajustar muitas regras de uma vez, por exemplo em período de inflação alta, sem depender de uma mudança técnica para cada valor.

**Decidido**
- **Solicitar e aprovar são passos separados:**
  - qualquer operador ativo da Central **simula** (vê o valor atual e o novo de cada regra) e **solicita**;
  - quem tem a permissão "aprovar reajuste de taxa" **aprova ou rejeita**;
  - quem solicitou não aprova o próprio pedido;
  - o solicitante ou um aprovador pode cancelar o pedido antes da decisão.
- Nada entra em vigor sem aprovação. Cada pedido tem um motivo obrigatório e pode citar um índice de referência (texto livre).
- O reajuste é em percentual (de −50% a +50% por lote, como proteção contra erro de digitação) ou em valor fixo (só para componentes em centavos).
- O escopo é escolhido por tipo, serviço, UF e componente. A regra nacional e os percentuais (como a comissão) só entram quando pedidos explicitamente.
- **Tudo ou nada:** a aprovação recalcula sobre as regras vigentes naquele momento. Se alguma regra impedir (valor "a definir", regra futura agendada, resultado negativo ou zerado, ou nada a alterar), o lote inteiro é recusado e nada muda.
- O reajuste começa na hora da aprovação ou numa data futura, **nunca no passado**.
- **Arredondamento:** uma única vez, ao centavo, sobre o valor final. Frações de 0,5 ou mais sobem e menores descem (1,5 vira 2; 1,49 vira 1).
- **Direito adquirido:** a regra anterior continua consultável. Um chamado em andamento mantém o preço registrado na hora do pedido.

**A definir**
- Tela de administração do reajuste. Hoje ele é feito pelas funções do banco.

**Fora do escopo atual**
- Busca automática de índice (IPCA).

## 8. Estado atual

### Decidido
- **Stack:** PostgreSQL com PostGIS, Keycloak (confirmação do Adailton pendente), Node.js com TypeScript no backend, e React com TypeScript, Vite e Tailwind no frontend.
- CPF do tomador no cadastro; CPF do responsável de PJ e MEI na aprovação; verificação do celular obrigatória.
- Parceiro tipificado, com as regras de viatura e de Susep por tipo.
- Garantia por pré-autorização no cartão ou Pix pré-pago.
- Nível 0 "cadastro incompleto" para todo cadastro novo.
- Regras de preço mudam só por mudança revisada no repositório, exceto o reajuste em lote, que é solicitado e aprovado pela Central.
- Aprovações por permissão individual. A autoaprovação está desligada por padrão e só se liga por mudança revisada no repositório. Na concessão de permissões, ela nunca pode ser ligada.
- Preço registrado na hora do pedido.
- Identidade visual do protótipo v8.
- Módulo de seguros na Fase 1 (o escopo está a definir).

### Construído
- **Banco de dados:** cadastro, parceiros, posição das viaturas, antifraude base, níveis, taxas, garantia, permissões da Central e reajuste em lote. Tudo com testes, inclusive de concorrência.
- **API:** esqueleto, com verificação de saúde e validação do login. Ainda sem regra de negócio.
- **Frontend:** esqueleto, com os componentes-base, os layouts e as rotas vazias. Ainda sem login nem formulários.
- **Protótipos:** o protótipo 1 (cadastro, verificação de e-mail, 2FA e login) está aprovado. Os protótipos 1 a 3 (cadastro e 2FA, verificação do parceiro, painel da Central) estão no canvas.

### A definir
- Confirmação do Keycloak e da regra de 2FA.
- Canal de verificação do celular (SMS ou WhatsApp).
- Escopo do módulo de seguros.
- Processador de pagamento.
- Regras de cancelamento.
- **Valores** de taxas e garantia.
- Requisitos de cada nível (hoje proposta) e nível mínimo por serviço.
- Uso de distância rodoviária na cobrança (depende da licença do SNV e dos termos do Google).
- Motor de rotas e tempo de chegada (serviço externo ou próprio).
- Retenção do histórico de GPS e base legal.
- O que fazer com um parceiro aprovado cujo documento vence.
- Novos tipos de parceiro.

### Futuro
- O chamado completo: pedido, aceite, acompanhamento, chat, avaliações, evidências, disputa, pagamento e repasse.
- Distância por rodovia (SNV ou outra base) na cobrança por km.
- Integração com o processador de pagamento escolhido.
- Tela de administração do reajuste.
- Área de atuação por polígono, se o centro com raio não bastar.
- Drones: ideia futura registrada; uso ainda não definido.

## 9. Mapa dos documentos

| Documento | Para quem | Conteúdo |
|---|---|---|
| [`README.md`](../README.md) | todos | apresentação curta e links |
| [`docs/COMO_FUNCIONA.md`](COMO_FUNCIONA.md) | sócios, parceiros, interessados | este documento: o produto e as regras |
| [`CLAUDE.md`](../CLAUDE.md) | equipe técnica | contexto, terminologia, regras inegociáveis, decisões tomadas e pendentes |
| [`docs/DESENVOLVIMENTO.md`](DESENVOLVIMENTO.md) | equipe técnica | como subir o ambiente, rodar a API, o frontend e os testes |
| [`docs/BANCO_DE_DADOS.md`](BANCO_DE_DADOS.md) | equipe técnica | modelo de dados, regras no banco, permissões, decisões de modelagem e pendências |
| [`docs/KEYCLOAK.md`](KEYCLOAK.md) | equipe técnica | configuração do serviço de identidade em desenvolvimento |
| [`docs/PLANO_FRONTEND.md`](PLANO_FRONTEND.md) | equipe técnica | plano do frontend, identidade visual e acessibilidade |
| [`docs/PROMPT_BANCO_INICIAL.md`](PROMPT_BANCO_INICIAL.md) | equipe técnica | especificação original da base de dados (histórico) |
| [`docs/safety_car_modelo_dados_v1.sql`](safety_car_modelo_dados_v1.sql) | equipe técnica | modelo de dados de referência (v1) |
| [`docs/marca/`](marca/) | todos | ícones da identidade visual |
| `db/`, `apps/api/`, `apps/web/`, `keycloak/` | equipe técnica | migrações e testes do banco, API, frontend e configuração do Keycloak |
| Documento de alinhamento | — | fora do repositório (perguntas de validação com o sócio) |
