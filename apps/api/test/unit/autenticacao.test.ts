import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { after, before, describe, test } from 'node:test';

import {
  createLocalJWKSet,
  exportJWK,
  generateKeyPair,
  type JWTPayload,
  type JWTVerifyGetKey,
  SignJWT,
} from 'jose';

import { construirApp } from '../../src/app.ts';
import { criarVerificadorKeycloak } from '../../src/autenticacao.ts';
import { bancoOk, LogCapturado } from '../apoio.ts';

const ISSUER = 'http://localhost:8080/realms/safetycar-dev';
const AUDIENCE = 'safetycar-api';
const SUB = randomUUID();

type ChavePrivada = Awaited<ReturnType<typeof generateKeyPair>>['privateKey'];
let chavePrivada: ChavePrivada;
let outraChavePrivada: ChavePrivada;
let chavesPublicas: JWTVerifyGetKey;

before(async () => {
  const par = await generateKeyPair('RS256');
  const outroPar = await generateKeyPair('RS256');
  chavePrivada = par.privateKey;
  outraChavePrivada = outroPar.privateKey;
  const jwk = { ...(await exportJWK(par.publicKey)), kid: 'chave-teste', alg: 'RS256' };
  chavesPublicas = createLocalJWKSet({ keys: [jwk] });
});

interface OpcoesToken {
  claims?: JWTPayload;
  chave?: ChavePrivada;
  /** exp em segundos desde a época; padrão: daqui a 5 min. */
  expiraEm?: number;
}

/** Token no formato do Keycloak (typ Bearer, iss do realm, aud com safetycar-api). */
async function token(opcoes: OpcoesToken = {}): Promise<string> {
  const agora = Math.floor(Date.now() / 1000);
  const exp = typeof opcoes.expiraEm === 'number' ? opcoes.expiraEm : agora + 300;
  // As claims do teste vêm por último: sobrescrevem as padrão (iss, aud, sub etc.).
  return new SignJWT({
    typ: 'Bearer',
    azp: 'safetycar-web',
    iss: ISSUER,
    aud: [AUDIENCE, 'account'],
    sub: SUB,
    iat: agora,
    exp,
    ...opcoes.claims,
  })
    .setProtectedHeader({ alg: 'RS256', kid: 'chave-teste', typ: 'JWT' })
    .sign(opcoes.chave ?? chavePrivada);
}

function montar(chaves: JWTVerifyGetKey = chavesPublicas) {
  const log = new LogCapturado();
  const app = construirApp({
    banco: bancoOk(),
    verificadorToken: criarVerificadorKeycloak({ issuer: ISSUER, audience: AUDIENCE, chaves }),
    nivelLog: 'trace',
    destinoLog: log,
  });
  return { app, log };
}

const apps: ReturnType<typeof montar>['app'][] = [];
after(async () => {
  await Promise.all(apps.map((app) => app.close()));
});

async function getEu(autorizacao?: string, chaves?: JWTVerifyGetKey) {
  const { app, log } = montar(chaves);
  apps.push(app);
  const resposta = await app.inject({
    method: 'GET',
    url: '/eu',
    headers: autorizacao === undefined ? {} : { authorization: autorizacao },
  });
  return { resposta, log };
}

async function esperar401(autorizacao: string | undefined, codigo: string) {
  const { resposta } = await getEu(autorizacao);
  assert.equal(resposta.statusCode, 401);
  assert.equal(resposta.json<{ erro: { codigo: string } }>().erro.codigo, codigo);
  assert.match(String(resposta.headers['www-authenticate']), /^Bearer realm="safetycar"/);
}

describe('GET /eu', () => {
  test('200 com token válido: devolve o keycloak_sub', async () => {
    const { resposta } = await getEu(`Bearer ${await token()}`);
    assert.equal(resposta.statusCode, 200);
    assert.deepEqual(resposta.json(), { keycloak_sub: SUB });
    assert.equal(resposta.headers['cache-control'], 'no-store');
  });

  test('aceita o esquema "bearer" em minúsculas', async () => {
    const { resposta } = await getEu(`bearer ${await token()}`);
    assert.equal(resposta.statusCode, 200);
  });

  test('401 sem cabeçalho Authorization', async () => {
    await esperar401(undefined, 'nao_autenticado');
  });

  test('401 com outro esquema (Basic)', async () => {
    await esperar401('Basic dXN1YXJpbzpzZW5oYQ==', 'nao_autenticado');
  });

  test('401 com token expirado', async () => {
    await esperar401(
      `Bearer ${await token({ expiraEm: Math.floor(Date.now() / 1000) - 60 })}`,
      'token_invalido',
    );
  });

  test('401 com emissor diferente', async () => {
    const t = await token({ claims: { iss: 'http://localhost:8080/realms/master' } });
    await esperar401(`Bearer ${t}`, 'token_invalido');
  });

  test('401 sem a audiência safetycar-api', async () => {
    const t = await token({ claims: { aud: 'account' } });
    await esperar401(`Bearer ${t}`, 'token_invalido');
  });

  test('401 com assinatura de outra chave', async () => {
    await esperar401(`Bearer ${await token({ chave: outraChavePrivada })}`, 'token_invalido');
  });

  test('401 com "alg: none" (token sem assinatura)', async () => {
    const corpo = { iss: ISSUER, aud: AUDIENCE, sub: SUB, typ: 'Bearer', exp: 9999999999, iat: 1 };
    const b64 = (o: object) => Buffer.from(JSON.stringify(o)).toString('base64url');
    await esperar401(`Bearer ${b64({ alg: 'none', typ: 'JWT' })}.${b64(corpo)}.`, 'token_invalido');
  });

  test('401 com ID token (typ "ID") em vez de token de acesso', async () => {
    await esperar401(`Bearer ${await token({ claims: { typ: 'ID' } })}`, 'token_invalido');
  });

  test('401 quando o sub não é uuid', async () => {
    await esperar401(`Bearer ${await token({ claims: { sub: 'nao-e-uuid' } })}`, 'token_invalido');
  });

  test('401 com texto que não é JWT', async () => {
    await esperar401('Bearer abc.def', 'token_invalido');
  });

  test('503 quando o Keycloak não fornece as chaves', async () => {
    const indisponivel: JWTVerifyGetKey = () => Promise.reject(new TypeError('fetch failed'));
    const { resposta } = await getEu(`Bearer ${await token()}`, indisponivel);
    assert.equal(resposta.statusCode, 503);
    assert.equal(
      resposta.json<{ erro: { codigo: string } }>().erro.codigo,
      'autenticacao_indisponivel',
    );
  });

  test('o log não contém o token nem o keycloak_sub', async () => {
    const t = await token();
    const { log } = await getEu(`Bearer ${t}`);
    const { log: logRecusa } = await getEu(`Bearer ${await token({ chave: outraChavePrivada })}`);
    for (const texto of [log.texto, logRecusa.texto]) {
      assert.ok(!texto.includes(SUB), 'o log contém o sub');
      assert.ok(!texto.includes(t.split('.')[1] ?? t), 'o log contém o token');
    }
    assert.match(log.texto, /"rota":"\/eu","status":200/);
  });
});
