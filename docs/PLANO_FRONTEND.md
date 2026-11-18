# Plano do frontend (`apps/web`)

Esqueleto do frontend do Safety Car em React + TypeScript + Vite + Tailwind. Plano **aprovado em 2026-11-18**. Ainda não implementado.

**Ordem:** o backend (`apps/api`) vem primeiro. O frontend só começa quando `GET /saude` existir na API.

## Escopo
1. Pasta `apps/web`, com TypeScript estrito, ESLint, Prettier e testes.
2. Tailwind com a identidade visual da v8 (cores abaixo), fonte Inter e logotipo.
3. Componentes-base: Botão (principal e secundário), Campo de texto (rótulo e erro), Campo de código de 6 dígitos, Indicador de etapas, Cartão de aviso e Selo de status (Aprovado, Em análise, Pendente, Vencido).
4. Layout móvel de 390 px com cabeçalho do logotipo, e layout de painel (menu lateral) para a Central.
5. Rotas vazias, só com o título: `/cadastro`, `/entrar`, `/verificacao` e `/central`.
6. Página `/componentes` de demonstração, apenas em desenvolvimento.
7. Estado de `GET /saude` na página inicial.
8. Acessibilidade: rótulos, foco visível, alvos de pelo menos 44 px e contraste mínimo de 4,5:1.
9. Seção no README e atualização do `CLAUDE.md`.

Fora do escopo: lógica de autenticação, formulários reais e réplica das 17 telas do canvas dos protótipos.

## Bibliotecas aprovadas
Instalação com versões exatas e `package-lock.json` versionado.

| Pacote | Tipo | Motivo |
|---|---|---|
| `react`, `react-dom` (19) | dep | interface |
| `react-router` (v7, modo declarativo) | dep | roteamento com layouts aninhados e `lazy`; o mais conhecido |
| `@fontsource-variable/inter` | dep | Inter hospedada no próprio app: sem Google Fonts (o IP do usuário não vai ao Google, por LGPD) e sem depender de rede externa |
| `vite`, `@vitejs/plugin-react` | dev | build e servidor de desenvolvimento |
| `typescript`, `@types/react`, `@types/react-dom` | dev | tipagem |
| `tailwindcss`, `@tailwindcss/vite` (v4) | dev | estilos; tokens no `@theme` do CSS, sem PostCSS nem `tailwind.config.js` |
| `eslint`, `@eslint/js`, `typescript-eslint`, `globals` | dev | lint |
| `eslint-plugin-react-hooks`, `eslint-plugin-react-refresh` | dev | regras de React |
| `eslint-plugin-jsx-a11y` | dev | falhas de acessibilidade no JSX |
| `prettier`, `eslint-config-prettier`, `prettier-plugin-tailwindcss` | dev | formatação e ordem das classes |
| `vitest`, `jsdom` | dev | testes; reaproveita a configuração do Vite |
| `@testing-library/react`, `@testing-library/user-event`, `@testing-library/jest-dom` | dev | testes de componente |
| `vitest-axe` | dev | auditoria automática de acessibilidade nos componentes |

- **React Hook Form**, com `@hookform/resolvers` e Zod: **só quando houver formulário real** (cadastro). Os campos já aceitam `ref`.
- Sem biblioteca de requisição: um `fetch` com tempo limite basta para o `/saude`.

## Identidade visual e contraste
Cores da v8, com as razões de contraste calculadas:

| Token | Cor | Uso |
|---|---|---|
| `marinho` | `#0B1F3A` | fundo escuro e títulos |
| `limao` | `#D4FF00` | botão principal |
| `fundo` | `#F4F7FB` | fundo claro |
| `texto` | `#14233B` | texto (14,66:1 no fundo) |
| `texto-sec` | `#4A5A73` | texto secundário (6,51:1 no fundo) |
| `borda` | `#C9D3E2` | **só** divisórias e cartões (1,51:1, decorativo) |
| `borda-campo` | `#4A5A73` | borda de campo de formulário (7:1; mínimo 3:1, WCAG 1.4.11) |
| `link` | `#1F4E9E` | links (7,40:1 no fundo) |

Regras aprovadas:
- **Botão principal:** fundo verde-limão com texto azul-marinho (14,24:1).
- **O verde-limão nunca vai sobre fundo claro** como texto, ícone ou anel de foco (1,08:1).
- **Foco:** anel azul-marinho no fundo claro e verde-limão no fundo azul-marinho.
- **Texto sobre o azul-marinho:** branco ou verde-limão. O `#4A5A73` reprova ali (2,36:1).
- **Selos de status:** cores tiradas do CSS da v8 e conferidas, sempre com o texto escrito no selo (a cor nunca é o único sinal).
- **Teste de contraste:** lê o `@theme` do `src/estilos.css` e confere os pares em uso (≥ 4,5:1 para texto e ≥ 3:1 para componentes). Trocar uma cor sem passar no teste quebra o build.

**Logotipo:**
- Origem: `plataforma/static/icon-512.png`, `icon-192.png` e `icon-apple.png` de `docs/Safety_Car_v8_PROJETO_COMPLETO_UNIFICADO.zip`.
- Destino: `docs/marca/`, versionado.
- No app: tamanhos de cerca de 96 px (cabeçalho), 192 px e 512 px (favicon e ícone), gerados com o `System.Drawing` do Windows, sem instalar nada.

## Desenho técnico
- **Estrutura:**
  - `apps/web/` é um pacote independente.
  - Pastas: `src/componentes/`, `src/layouts/`, `src/paginas/` e `src/api/`. Os testes ficam ao lado de cada arquivo (`*.test.tsx`).
- **TypeScript:** `strict`, `noUncheckedIndexedAccess` e `exactOptionalPropertyTypes`.
- **Componentes:**
  - **Botão:** `principal` e `secundario` (contorno). Altura mínima de 44 px, foco visível e estado desabilitado.
  - **CampoTexto:** rótulo sempre visível (`useId`) e dica opcional. O erro marca o campo com `aria-invalid` e é anunciado por `aria-describedby`.
  - **CampoCodigo:**
    - **Um único `<input>`** (`inputMode="numeric"`, `autoComplete="one-time-code"`, 6 dígitos) desenhado como 6 caixas.
    - Assim, colar o código e o preenchimento automático funcionam, e o leitor de tela ouve um campo só.
  - **IndicadorEtapas:** `<ol>` com `aria-current="step"` e o texto "Etapa N de M".
  - **CartaoAviso:**
    - Variantes `info`, `atencao` e `erro`.
    - `role="alert"` só quando o aviso aparece em reação a uma ação.
  - **SeloStatus:** `aprovado`, `em_analise`, `pendente` e `vencido`, os mesmos valores do banco onde se aplicam.
- **Layouts:**
  - **LayoutMovel:** coluna de no máximo 390 px com cabeçalho do logotipo. Vale para `/`, `/cadastro`, `/entrar` e `/verificacao`.
  - **LayoutPainel:** menu lateral para `/central`, que vira gaveta em tela estreita. Um único item ("Painel") até as telas da Central serem definidas.
- **Rotas:**
  - Cada rota tem só o `<h1>` e o `document.title`. Há também uma página 404.
  - `/componentes` é registrada só com `import.meta.env.DEV` e carregada sob demanda. Um teste confere que ela não está no `dist/`.
- **`/saude`:**
  - Proxy do Vite `/api` → `http://127.0.0.1:3000`, removendo o prefixo, sem CORS.
  - Configuração: `VITE_API_BASE` (padrão `/api`) e `API_URL_DEV`.
  - Estados: verificando, ok, banco indisponível (503) e API indisponível (rede ou tempo esgotado), anunciados com `role="status"`.
- **Acessibilidade:** `lang="pt-BR"`, link "Pular para o conteúdo", `:focus-visible` com anel de 2 px e deslocamento, e respeito a `prefers-reduced-motion`.

## Etapas
Um commit por etapa. Ao fim de cada uma, mostrar a saída de `lint`, `test` e `build`.
1. Fundação: Vite, React, TS estrito, ESLint, Prettier, Vitest e um teste mínimo.
2. Identidade: Tailwind, tokens, Inter, logotipo e teste de contraste.
3. Componentes-base, com testes.
4. Layouts, roteamento e `/componentes` (só em desenvolvimento).
5. Estado da API na página inicial.
6. README e `CLAUDE.md`.
