// Executado antes de cada arquivo de teste.
import '@testing-library/jest-dom/vitest';
import { cleanup } from '@testing-library/react';
import { afterEach, expect } from 'vitest';
import * as matchersAxe from 'vitest-axe/matchers';

// Auditoria de acessibilidade: expect(await axe(container)).toHaveNoViolations().
// O jsdom não calcula layout, então a regra de contraste do axe não se aplica aqui;
// o contraste é conferido pelo src/estilos.test.ts.
expect.extend(matchersAxe);

// Sem "globals" no Vitest, a Testing Library não desmonta sozinha entre os testes.
afterEach(() => {
  cleanup();
});
