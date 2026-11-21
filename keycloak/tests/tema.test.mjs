// Estrutura do tema de login "safetycar" (sem Keycloak rodando, sem dependências).
//
//   node --test keycloak/tests
//
// Confere: tema pai e propriedades; arquivos referenciados existem; nenhuma URL externa nem
// @import; nenhum template .ftl; mensagens em UTF-8, sem script e com HTML mínimo no cabeçalho;
// fontes com licença; contraste de 4,5:1 nos pares de texto (lidos das variáveis do :root);
// verde-limão nunca sobre o fundo claro do desktop; loginTheme no realm versionado.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, existsSync, statSync } from 'node:fs';
import { join, dirname, resolve, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const RAIZ = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const TEMA = join(RAIZ, 'keycloak', 'themes', 'safetycar', 'login');
const RECURSOS = join(TEMA, 'resources');
const CSS = join(RECURSOS, 'css', 'safetycar.css');
const MENSAGENS = join(TEMA, 'messages', 'messages_pt_BR.properties');

// Templates .ftl sobrescritos: cada um é custo em upgrade. Para acrescentar, justifique aqui
// e em docs/KEYCLOAK.md.
const FTL_PERMITIDOS = new Set([]);
// Estilos herdados do tema pai (keycloak.v2), que não ficam neste diretório.
const ESTILOS_DO_PAI = new Set(['css/styles.css']);

const ler = (p) => readFileSync(p, 'utf8');

function arquivos(dir) {
  return readdirSync(dir).flatMap((nome) => {
    const p = join(dir, nome);
    return statSync(p).isDirectory() ? arquivos(p) : [p];
  });
}

function propriedades(texto) {
  const r = {};
  for (const linha of texto.split(/\r?\n/)) {
    const m = /^([^#!\s][^=]*?)\s*=\s*(.*)$/.exec(linha);
    if (m) r[m[1]] = m[2];
  }
  return r;
}

const semComentarios = (css) => css.replace(/\/\*[\s\S]*?\*\//g, '');
const semDataUris = (texto) => texto.replace(/url\(\s*(["']?)data:[^)]*?\1\s*\)/g, 'url(data)');

// Devolve o conteúdo do bloco @media que começa em `inicio` (casando as chaves).
function blocoMedia(css, cabecalho) {
  const i = css.indexOf(cabecalho);
  assert.ok(i >= 0, `bloco ${cabecalho} não encontrado`);
  let nivel = 0;
  for (let j = css.indexOf('{', i); j < css.length; j++) {
    if (css[j] === '{') nivel++;
    else if (css[j] === '}' && --nivel === 0) return css.slice(css.indexOf('{', i) + 1, j);
  }
  throw new Error(`bloco ${cabecalho} sem fechamento`);
}

// Regras de nível superior (fora de @media e @font-face): [{seletores, corpo}].
function regrasDeTopo(css) {
  let semBlocos = css;
  for (;;) {
    const i = semBlocos.search(/@(media|font-face)[^{]*\{/);
    if (i < 0) break;
    let nivel = 0, j = semBlocos.indexOf('{', i);
    for (; j < semBlocos.length; j++) {
      if (semBlocos[j] === '{') nivel++;
      else if (semBlocos[j] === '}' && --nivel === 0) break;
    }
    semBlocos = semBlocos.slice(0, i) + semBlocos.slice(j + 1);
  }
  return [...semBlocos.matchAll(/([^{}]+)\{([^{}]*)\}/g)].map((m) => ({
    seletores: m[1].split(',').map((s) => s.trim().replace(/\s+/g, ' ')),
    corpo: m[2],
  }));
}

// ---------------------------------------------------------------- cores e contraste

function cor(valor) {
  const v = valor.trim();
  let m = /^#([0-9a-f]{6})$/i.exec(v);
  if (m) {
    const n = parseInt(m[1], 16);
    return { r: n >> 16, g: (n >> 8) & 255, b: n & 255, a: 1 };
  }
  m = /^rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*(?:,\s*([\d.]+))?\s*\)$/i.exec(v);
  if (m) return { r: +m[1], g: +m[2], b: +m[3], a: m[4] === undefined ? 1 : +m[4] };
  throw new Error(`cor não reconhecida: ${valor}`);
}

// Compõe uma cor (possivelmente translúcida) sobre um fundo opaco.
const sobre = (frente, fundo) => ({
  r: frente.r * frente.a + fundo.r * (1 - frente.a),
  g: frente.g * frente.a + fundo.g * (1 - frente.a),
  b: frente.b * frente.a + fundo.b * (1 - frente.a),
  a: 1,
});

function luminancia({ r, g, b }) {
  const canal = (c) => {
    const s = c / 255;
    return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * canal(r) + 0.7152 * canal(g) + 0.0722 * canal(b);
}

function contraste(a, b) {
  const [l1, l2] = [luminancia(a), luminancia(b)].sort((x, y) => y - x);
  return (l1 + 0.05) / (l2 + 0.05);
}

function variaveisRoot(css) {
  const bloco = /:root\s*\{([\s\S]*?)\}/.exec(css);
  assert.ok(bloco, ':root não encontrado');
  const vars = {};
  for (const m of bloco[1].matchAll(/(--sc-[\w-]+)\s*:\s*([^;]+);/g)) vars[m[1]] = m[2].trim();
  return vars;
}

// ---------------------------------------------------------------- testes

test('theme.properties: pai keycloak.v2, sem modo escuro, estilos existentes', () => {
  const p = propriedades(ler(join(TEMA, 'theme.properties')));
  assert.equal(p.parent, 'keycloak.v2');
  assert.equal(p.import, 'common/keycloak');
  assert.equal(p.darkMode, 'false');
  assert.ok(!('scripts' in p), 'o tema não acrescenta scripts');
  const estilos = (p.styles ?? '').split(/\s+/).filter(Boolean);
  assert.ok(estilos.includes('css/safetycar.css'));
  for (const e of estilos) {
    if (ESTILOS_DO_PAI.has(e)) continue;
    assert.ok(existsSync(join(RECURSOS, e)), `estilo listado não existe: ${e}`);
  }
});

test('nenhum template .ftl fora da lista permitida', () => {
  const ftl = arquivos(TEMA).filter((f) => f.endsWith('.ftl')).map((f) => relative(TEMA, f).split(sep).join('/'));
  assert.deepEqual(ftl.filter((f) => !FTL_PERMITIDOS.has(f)), []);
});

test('CSS: toda url() é do próprio tema (existe) ou SVG embutido; nada externo', () => {
  const css = semComentarios(ler(CSS));
  assert.doesNotMatch(css, /@import/i, 'sem @import');
  const urls = [...css.matchAll(/url\(\s*(["']?)(.*?)\1\s*\)/g)].map((m) => m[2]);
  assert.ok(urls.length > 0);
  for (const u of urls) {
    if (u.startsWith('data:')) {
      assert.match(u, /^data:image\/svg\+xml,/, `data: só para SVG: ${u.slice(0, 40)}`);
      assert.doesNotMatch(decodeURIComponent(u), /<script|href=|xlink:href|javascript:/i, 'SVG embutido sem script nem link');
      continue;
    }
    assert.doesNotMatch(u, /^([a-z]+:|\/)/i, `url() deve ser relativa ao CSS: ${u}`);
    const alvo = resolve(dirname(CSS), u);
    assert.ok(alvo.startsWith(RECURSOS + sep), `url() sai dos recursos do tema: ${u}`);
    assert.ok(existsSync(alvo), `url() aponta para arquivo inexistente: ${u}`);
  }
  // Fora dos data: (cujo xmlns é só um nome), nenhum endereço.
  assert.doesNotMatch(semDataUris(css), /https?:|\/\/[a-z0-9]/i, 'nenhuma URL absoluta no CSS');
});

test('fontes: cada @font-face aponta para woff2 do tema, com licença', () => {
  const css = semComentarios(ler(CSS));
  const faces = [...css.matchAll(/@font-face\s*\{([^}]*)\}/g)].map((m) => m[1]);
  assert.equal(faces.length, 2);
  for (const f of faces) assert.match(f, /url\("\.\.\/fonts\/[\w.-]+\.woff2"\)/);
  for (const lic of ['LICENSE-inter.txt', 'LICENSE-playfair-display.txt']) {
    assert.match(ler(join(RECURSOS, 'fonts', lic)), /SIL Open Font License/);
  }
});

test('mensagens: UTF-8, sem script nem URL, sem aspas simples, cabeçalho com HTML mínimo', () => {
  const bruto = readFileSync(MENSAGENS);
  const texto = new TextDecoder('utf-8', { fatal: true }).decode(bruto);
  assert.doesNotMatch(texto, /<script|javascript:/i);
  assert.doesNotMatch(texto, /<[^>]*\son\w+\s*=/i, 'nenhum atributo de evento (onclick etc.) em HTML');
  assert.doesNotMatch(texto, /https?:\/\//i);
  const m = propriedades(texto);
  for (const [chave, valor] of Object.entries(m)) {
    assert.ok(!valor.includes("'"), `${chave}: aspa simples quebra o MessageFormat`);
  }
  assert.equal(m.invalidUserMessage, 'E-mail ou senha inválidos.');
  assert.equal(m.accountTemporarilyDisabledMessage, m.invalidUserMessage, 'bloqueio temporário não se distingue');
  for (const tag of m.loginTitleHtml.matchAll(/<\/?([a-z0-9]+)([^>]*)>/gi)) {
    assert.equal(tag[1], 'span', `loginTitleHtml: só <span> (${tag[0]})`);
    assert.match(tag[2].trim(), /^(class="[\w -]+")?$/, `loginTitleHtml: só class (${tag[0]})`);
  }
  assert.match(m.loginTitleHtml, /class="sc-nome">SAFETY CAR</);
});

test('contraste de 4,5:1 em todos os pares de texto', () => {
  const v = variaveisRoot(ler(CSS));
  const c = (nome) => {
    assert.ok(v[nome], `variável ${nome} não definida no :root`);
    return cor(v[nome]);
  };
  const fundo = c('--sc-fundo');
  // Fundos escuros possíveis: o fundo e cada painel diagonal sobre ele.
  const escuros = [fundo, sobre(c('--sc-diagonal-1'), fundo), sobre(c('--sc-diagonal-2'), fundo)];
  // O cartão translúcido sobre cada um deles.
  const cartao = escuros.map((e) => sobre(c('--sc-cartao'), e));

  const pares = [
    // [descrição, texto, fundos]
    ['celular: texto e links no cartão', '--sc-texto-escuro-fundo', cartao],
    ['celular: rótulos no cartão', '--sc-rotulo-escuro-fundo', cartao],
    ['celular: "Criar conta" no cartão', '--sc-limao', cartao],
    ['cabeçalho: nome sobre o fundo', '--sc-texto-escuro-fundo', escuros],
    ['desktop: frase do painel azul', '--sc-rotulo-escuro-fundo', escuros],
    ['celular: texto do campo', '--sc-campo-texto', [c('--sc-campo-fundo')]],
    ['celular: botão e números dos passos', '--sc-marinho', [c('--sc-limao')]],
    ['erro: texto na caixa', '--sc-erro-texto', [c('--sc-erro-fundo')]],
    ['desktop: texto e rótulos', '--sc-claro-texto', [c('--sc-claro-fundo')]],
    ['desktop: links', '--sc-claro-link', [c('--sc-claro-fundo')]],
    ['desktop: texto do campo', '--sc-campo-texto', [c('--sc-claro-campo-fundo')]],
    ['desktop: botão e números dos passos', '--sc-claro-botao-texto', [c('--sc-claro-botao-fundo')]],
  ];
  const falhas = [];
  for (const [desc, texto, fundos] of pares) {
    const minimo = Math.min(...fundos.map((f) => contraste(c(texto), f)));
    if (minimo < 4.5) falhas.push(`${desc}: ${minimo.toFixed(2)}:1`);
  }
  assert.deepEqual(falhas, [], 'pares abaixo de 4,5:1');
});

test('desktop: botão azul-marinho com texto branco e nenhum verde-limão sobre o fundo claro', () => {
  const css = semComentarios(ler(CSS));
  const v = variaveisRoot(css);
  assert.equal(v['--sc-claro-botao-fundo'].toUpperCase(), '#0B1F3A');
  assert.equal(v['--sc-claro-botao-texto'].toUpperCase(), '#FFFFFF');
  const desktop = blocoMedia(css, '@media (min-width: 960px)');
  assert.doesNotMatch(desktop, /--sc-limao|#D4FF00/i, 'verde-limão no bloco do desktop');
  assert.match(desktop, /\.pf-v5-c-button\.pf-m-primary\s*\{[^}]*background-color:\s*var\(--sc-claro-botao-fundo\)/);
  // Toda regra do celular que usa verde-limão precisa ser sobrescrita no desktop.
  const seletoresDesktop = new Set(
    [...desktop.matchAll(/([^{}]+)\{[^{}]*\}/g)].flatMap((m) => m[1].split(',').map((s) => s.trim().replace(/\s+/g, ' '))),
  );
  const sobrando = regrasDeTopo(css)
    .filter((r) => /--sc-limao/.test(r.corpo))
    .flatMap((r) => r.seletores)
    .filter((s) => s !== ':root' && !seletoresDesktop.has(s));
  assert.deepEqual(sobrando, [], 'regras com verde-limão sem sobrescrita no desktop');
});

test('realm versionado usa o tema', () => {
  const realm = JSON.parse(ler(join(RAIZ, 'keycloak', 'realms', 'safetycar-dev.json')));
  assert.equal(realm.loginTheme, 'safetycar');
  assert.equal(realm.defaultLocale, 'pt-BR');
  assert.deepEqual(realm.supportedLocales, ['pt-BR']);
});
