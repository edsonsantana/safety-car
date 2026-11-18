import assert from 'node:assert/strict';
import { test } from 'node:test';

import { NOME_SERVICO } from '../../src/identidade.ts';

test('nome do serviço', () => {
  assert.equal(NOME_SERVICO, 'safetycar-api');
});
