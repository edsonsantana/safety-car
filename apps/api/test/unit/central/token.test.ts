// Claims de autenticação extraídas pelo verificador (acr, amr, auth_time), sem confiar no formato.
import assert from 'node:assert/strict';
import { before, test } from 'node:test';

import {
  type Chaves,
  gerarChaves,
  tokenCentral,
  uuidTeste,
  verificadorCentral,
} from '../../apoio-central.ts';

const SUB = uuidTeste(0x71);
let chaves: Chaves;
before(async () => {
  chaves = await gerarChaves();
});

test('devolve sub, acr, amr e auth_time do token', async () => {
  const authTime = Math.floor(Date.now() / 1000) - 30;
  const token = await tokenCentral(chaves, SUB, { auth_time: authTime });
  assert.deepEqual(await verificadorCentral(chaves).verificar(token), {
    sub: SUB,
    acr: '2',
    amr: ['pwd', 'otp'],
    authTime,
  });
});

test('claims fora do formato são descartadas, não convertidas', async () => {
  const token = await tokenCentral(chaves, SUB, {
    acr: 2,
    amr: ['otp', 7, null, 'pwd'],
    auth_time: '1700000000',
  });
  assert.deepEqual(await verificadorCentral(chaves).verificar(token), {
    sub: SUB,
    acr: undefined,
    amr: ['otp', 'pwd'],
    authTime: undefined,
  });
});

test('amr ausente vira lista vazia', async () => {
  const token = await tokenCentral(chaves, SUB, { amr: undefined });
  assert.deepEqual((await verificadorCentral(chaves).verificar(token)).amr, []);
});
