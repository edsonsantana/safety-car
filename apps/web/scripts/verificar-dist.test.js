// Roda no fim do "npm run build" (node:test, sem dependências):
// confere que a página /componentes, só de desenvolvimento, não foi para o dist/.
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';

const dist = join(import.meta.dirname, '..', 'dist');
const arquivos = readdirSync(dist, { recursive: true, withFileTypes: true })
  .filter((a) => a.isFile())
  .map((a) => join(a.parentPath, a.name));

test('o dist/ existe e tem o index.html', () => {
  assert.ok(arquivos.some((a) => a.endsWith('index.html')));
});

test('a página /componentes não está no dist/', () => {
  for (const arquivo of arquivos) {
    assert.doesNotMatch(arquivo, /Componentes/, `arquivo da página de demonstração: ${arquivo}`);
    if (/\.(js|html|css)$/.test(arquivo)) {
      const conteudo = readFileSync(arquivo, 'utf8');
      assert.ok(
        !conteudo.includes('Demonstração dos componentes-base'),
        `texto da página de demonstração em ${arquivo}`,
      );
    }
  }
});
