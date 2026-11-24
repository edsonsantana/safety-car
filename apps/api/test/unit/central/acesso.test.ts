// Guardas da Central: token do client certo, acr exato de nível 2, ator pelo sub, 403 uniforme
// e OTP recente. Tokens assinados com chaves locais; valores fictícios.
import assert from 'node:assert/strict';
import { after, before, describe, test } from 'node:test';

import type { FastifyInstance } from 'fastify';
import { SignJWT } from 'jose';

import {
  contexto,
  exigeOtpRecente,
  exigePermissao,
  exigeSessaoCentral,
} from '../../../src/central/acesso.ts';
import { ErroFuncaoBanco } from '../../../src/central/erros.ts';
import { criarLimites } from '../../../src/central/limite.ts';
import {
  ACR_NIVEL_2,
  AUDIENCE,
  BancoCentralFalso,
  type Chaves,
  CLIENT_WEB,
  corpoErro,
  gerarChaves,
  ISSUER,
  montarAppCentral,
  OTP_RECENTE_S,
  tokenCentral,
  uuidTeste,
  verificadorCentral,
} from '../../apoio-central.ts';

const SUB_ADMIN = uuidTeste(0xa1);
const SUB_SEM_PERMISSAO = uuidTeste(0xa2);
const SUB_DESCONHECIDO = uuidTeste(0xa9);
const ATOR_ADMIN = uuidTeste(0xc1);
const ATOR_SEM_PERMISSAO = uuidTeste(0xc2);

let chaves: Chaves;
const apps: FastifyInstance[] = [];
before(async () => {
  chaves = await gerarChaves();
});
after(async () => {
  await Promise.all(apps.map((app) => app.close()));
});

function novoBanco() {
  return new BancoCentralFalso(
    new Map([
      [
        SUB_ADMIN,
        { ator: ATOR_ADMIN, permissoes: [{ codigo: 'conceder_permissao', sensivel: true }] },
      ],
      [SUB_SEM_PERMISSAO, { ator: ATOR_SEM_PERMISSAO, permissoes: [] }],
    ]),
  );
}

/**
 * App da Central com uma rota sensível de teste (★): sessão, permissão conceder_permissao e
 * OTP recente, na ordem do plano. A rota fica fora do plugin, só para exercitar as guardas.
 */
function montar(banco = novoBanco(), agora: () => number = Date.now) {
  const montado = montarAppCentral({ chaves, banco, agora });
  const sessao = exigeSessaoCentral({
    verificador: verificadorCentral(chaves),
    banco,
    acr: ACR_NIVEL_2,
    limites: criarLimites(agora),
  });
  montado.app.post(
    '/teste/sensivel',
    {
      preHandler: [
        sessao,
        exigePermissao(banco, 'conceder_permissao'),
        exigeOtpRecente(ACR_NIVEL_2, OTP_RECENTE_S, agora),
      ],
    },
    (req) => Promise.resolve({ ok: contexto(req).ator === ATOR_ADMIN }),
  );
  apps.push(montado.app);
  return { ...montado, banco };
}

const bearer = (token: string) => ({ authorization: `Bearer ${token}` });

describe('sessão da Central: token e segundo fator', () => {
  test('sem token: 401 nao_autenticado', async () => {
    const { app } = montar();
    const resposta = await app.inject({ method: 'GET', url: '/central/eu' });
    assert.equal(resposta.statusCode, 401);
    assert.equal(corpoErro(resposta).codigo, 'nao_autenticado');
    assert.equal(resposta.headers['cache-control'], 'no-store');
  });

  test('token do client do app (azp safetycar-web) não entra na Central', async () => {
    const { app } = montar();
    const token = await tokenCentral(chaves, SUB_ADMIN, { azp: CLIENT_WEB });
    const resposta = await app.inject({
      method: 'GET',
      url: '/central/eu',
      headers: bearer(token),
    });
    assert.equal(resposta.statusCode, 401);
    assert.equal(corpoErro(resposta).codigo, 'token_invalido');
  });

  // Risco 3 do plano: só o acr exato do nível 2 configurado; "1" (senha) e "0" (SSO) nunca.
  const acrsRecusados: [string, unknown][] = [
    ['acr "1" (só senha)', '1'],
    ['acr "0" (sessão reaproveitada pelo SSO)', '0'],
    ['acr ausente', undefined],
    ['acr numérico 2 (não é o texto configurado)', 2],
    ['acr " 2" (com espaço)', ' 2'],
    ['acr "2 " (com espaço)', '2 '],
    ['acr "3" (outro nível)', '3'],
    ['acr "otp" (nome em vez do valor configurado)', 'otp'],
    ['acr em lista', ['2']],
  ];
  for (const [descricao, acr] of acrsRecusados) {
    test(`${descricao}: 401 segundo_fator_exigido, sem consultar o banco`, async () => {
      const banco = novoBanco();
      let consultas = 0;
      const original = banco.atorPorSub.bind(banco);
      banco.atorPorSub = (sub) => {
        consultas += 1;
        return original(sub);
      };
      const { app } = montar(banco);
      const token = await tokenCentral(chaves, SUB_ADMIN, { acr });
      const resposta = await app.inject({
        method: 'GET',
        url: '/central/eu',
        headers: bearer(token),
      });
      assert.equal(resposta.statusCode, 401);
      assert.equal(corpoErro(resposta).codigo, 'segundo_fator_exigido');
      assert.equal(
        resposta.headers['www-authenticate'],
        'Bearer realm="safetycar", error="insufficient_user_authentication", acr_values="2"',
      );
      assert.equal(consultas, 0);
    });
  }

  test('auth_time ausente ou inválido: 401 segundo_fator_exigido', async () => {
    const { app } = montar();
    for (const authTime of [undefined, 'agora', -1, 1.5]) {
      const token = await tokenCentral(chaves, SUB_ADMIN, { auth_time: authTime });
      const resposta = await app.inject({
        method: 'GET',
        url: '/central/eu',
        headers: bearer(token),
      });
      assert.equal(resposta.statusCode, 401, `auth_time ${String(authTime)}`);
      assert.equal(corpoErro(resposta).codigo, 'segundo_fator_exigido');
    }
  });

  test('token assinado com outra chave: 401 token_invalido', async () => {
    const { app } = montar();
    const outras = await gerarChaves();
    const token = await new SignJWT({ typ: 'Bearer', azp: 'safetycar-central', sub: SUB_ADMIN })
      .setProtectedHeader({ alg: 'RS256', kid: 'chave-teste' })
      .setIssuer(ISSUER)
      .setAudience(AUDIENCE)
      .setIssuedAt()
      .setExpirationTime('5m')
      .sign(outras.privada);
    const resposta = await app.inject({
      method: 'GET',
      url: '/central/eu',
      headers: bearer(token),
    });
    assert.equal(resposta.statusCode, 401);
    assert.equal(corpoErro(resposta).codigo, 'token_invalido');
  });
});

describe('403 uniforme (não revela se o operador existe)', () => {
  test('sem operador, sem permissão e SC016 do banco: o mesmo status, corpo e cabeçalhos', async () => {
    const banco = novoBanco();
    const { app } = montar(banco);

    // 1) sub sem operador ativo (ator_central devolve NULL)
    const semOperador = await app.inject({
      method: 'POST',
      url: '/central/sessao',
      headers: bearer(await tokenCentral(chaves, SUB_DESCONHECIDO)),
    });
    // 2) operador ativo, mas o banco recusa com SC016 (ex.: desativado entre as duas consultas)
    banco.falhaRegistro = new ErroFuncaoBanco('registrar_acesso_central', 'SC016');
    const sc016 = await app.inject({
      method: 'POST',
      url: '/central/sessao',
      headers: bearer(await tokenCentral(chaves, SUB_ADMIN)),
    });
    // 3) operador ativo sem a permissão da rota
    const semPermissao = await app.inject({
      method: 'POST',
      url: '/teste/sensivel',
      headers: bearer(await tokenCentral(chaves, SUB_SEM_PERMISSAO)),
    });

    for (const resposta of [semOperador, sc016, semPermissao]) {
      assert.equal(resposta.statusCode, 403);
      assert.equal(resposta.body, semOperador.body);
    }
    assert.deepEqual(corpoErro(semOperador), {
      codigo: 'acesso_negado',
      mensagem: 'Acesso negado.',
    });
    const semVariaveis = (h: Record<string, unknown>) =>
      Object.fromEntries(Object.entries(h).filter(([k]) => k !== 'x-request-id' && k !== 'date'));
    assert.deepEqual(semVariaveis(sc016.headers), semVariaveis(semOperador.headers));
  });
});

describe('OTP recente (★, 10 minutos)', () => {
  // Base fixa tirada do relógio real: o exp do token é conferido pelo jose com o relógio real.
  const AGORA = Date.now();
  const relogio = () => AGORA;
  const tokenComIdade = (idadeS: number) =>
    tokenCentral(chaves, SUB_ADMIN, { auth_time: Math.floor(AGORA / 1000) - idadeS }, AGORA);

  for (const idade of [0, 300, 599, 600, -3]) {
    test(`auth_time de ${String(idade)} s atrás: liberado`, async () => {
      const { app } = montar(novoBanco(), relogio);
      const resposta = await app.inject({
        method: 'POST',
        url: '/teste/sensivel',
        headers: bearer(await tokenComIdade(idade)),
      });
      assert.equal(resposta.statusCode, 200);
      assert.deepEqual(resposta.json(), { ok: true });
    });
  }

  for (const idade of [601, 3600, -60]) {
    test(`auth_time de ${String(idade)} s atrás: 401 otp_recente_exigido com max_age=600`, async () => {
      const { app } = montar(novoBanco(), relogio);
      const resposta = await app.inject({
        method: 'POST',
        url: '/teste/sensivel',
        headers: bearer(await tokenComIdade(idade)),
      });
      assert.equal(resposta.statusCode, 401);
      assert.equal(corpoErro(resposta).codigo, 'otp_recente_exigido');
      assert.equal(
        resposta.headers['www-authenticate'],
        'Bearer realm="safetycar", error="insufficient_user_authentication", acr_values="2", max_age=600',
      );
    });
  }

  test('sem permissão, o 403 vem antes do pedido de OTP (não induz novo login à toa)', async () => {
    const { app } = montar(novoBanco(), relogio);
    const token = await tokenCentral(
      chaves,
      SUB_SEM_PERMISSAO,
      { auth_time: Math.floor(AGORA / 1000) - 3600 },
      AGORA,
    );
    const resposta = await app.inject({
      method: 'POST',
      url: '/teste/sensivel',
      headers: bearer(token),
    });
    assert.equal(resposta.statusCode, 403);
  });
});
