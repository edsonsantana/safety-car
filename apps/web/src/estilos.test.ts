import { describe, expect, test } from 'vitest';
import css from './estilos.css?raw';

// Lê as cores do @theme: trocar uma cor sem passar aqui quebra o build.
const cores = new Map(
  [...css.matchAll(/--color-([a-z-]+):\s*(#[0-9a-f]{6})\s*;/gi)].map(
    ([, nome, hex]) => [nome, hex] as [string, string],
  ),
);

function cor(nome: string): string {
  const hex = cores.get(nome);
  if (!hex) {
    throw new Error(`Cor --color-${nome} não encontrada no @theme`);
  }
  return hex;
}

// Luminância relativa e razão de contraste da WCAG 2.x.
function luminancia(hex: string): number {
  const [r, g, b] = [1, 3, 5].map((i) => {
    const c = parseInt(hex.slice(i, i + 2), 16) / 255;
    return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  }) as [number, number, number];
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

function razaoContraste(a: string, b: string): number {
  const [clara, escura] = [luminancia(a), luminancia(b)].sort((x, y) => y - x) as [number, number];
  return (clara + 0.05) / (escura + 0.05);
}

const TEXTO = 4.5;
const COMPONENTE = 3;

// [frente, fundo, mínimo, uso]
const paresEmUso: [string, string, number, string][] = [
  ['texto', 'fundo', TEXTO, 'texto no fundo claro'],
  ['texto', 'branco', TEXTO, 'texto em cartão e campo'],
  ['texto-sec', 'fundo', TEXTO, 'texto secundário no fundo claro'],
  ['texto-sec', 'branco', TEXTO, 'dica de campo'],
  ['link', 'fundo', TEXTO, 'link no fundo claro'],
  ['link', 'branco', TEXTO, 'link em cartão'],
  ['marinho', 'fundo', TEXTO, 'títulos'],
  ['marinho', 'branco', TEXTO, 'botão secundário'],
  ['marinho', 'limao', TEXTO, 'botão principal'],
  ['branco', 'marinho', TEXTO, 'texto sobre o azul-marinho'],
  ['limao', 'marinho', TEXTO, 'destaque sobre o azul-marinho'],
  ['erro', 'fundo', TEXTO, 'mensagem de erro de campo'],
  ['erro', 'branco', TEXTO, 'mensagem de erro em cartão'],
  ['selo-aprovado-texto', 'selo-aprovado-fundo', TEXTO, 'selo Aprovado'],
  ['selo-em-analise-texto', 'selo-em-analise-fundo', TEXTO, 'selo Em análise'],
  ['selo-pendente-texto', 'selo-pendente-fundo', TEXTO, 'selo Pendente'],
  ['selo-vencido-texto', 'selo-vencido-fundo', TEXTO, 'selo Vencido'],
  ['aviso-info-texto', 'aviso-info-fundo', TEXTO, 'aviso informativo'],
  ['aviso-atencao-texto', 'aviso-atencao-fundo', TEXTO, 'aviso de atenção'],
  ['aviso-erro-texto', 'aviso-erro-fundo', TEXTO, 'aviso de erro'],
  ['borda-campo', 'branco', COMPONENTE, 'borda de campo'],
  ['borda-campo', 'fundo', COMPONENTE, 'borda de campo no fundo claro'],
  ['erro', 'branco', COMPONENTE, 'borda de campo com erro'],
  ['marinho', 'fundo', COMPONENTE, 'anel de foco e contorno no fundo claro'],
  ['marinho', 'branco', COMPONENTE, 'anel de foco em cartão'],
  ['limao', 'marinho', COMPONENTE, 'anel de foco sobre o azul-marinho'],
];

describe('contraste das cores do @theme', () => {
  test.each(paresEmUso)('%s sobre %s ≥ %s:1 (%s)', (frente, fundo, minimo) => {
    expect(razaoContraste(cor(frente), cor(fundo))).toBeGreaterThanOrEqual(minimo);
  });

  // Combinações proibidas pelo plano: o teste documenta por que não usá-las.
  test('verde-limão sobre fundo claro reprova até para componente', () => {
    expect(razaoContraste(cor('limao'), cor('fundo'))).toBeLessThan(COMPONENTE);
  });

  test('texto secundário sobre o azul-marinho reprova', () => {
    expect(razaoContraste(cor('texto-sec'), cor('marinho'))).toBeLessThan(TEXTO);
  });

  test('confere a razão calculada com valores conhecidos', () => {
    expect(razaoContraste('#000000', '#ffffff')).toBeCloseTo(21, 5);
    expect(razaoContraste(cor('texto'), cor('fundo'))).toBeCloseTo(14.66, 1);
  });
});
