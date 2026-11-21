import assert from 'node:assert/strict';
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
import type { Acesso, Banco } from '../../src/banco.ts';
import { bancoFalso, LogCapturado } from '../apoio.ts';

// Valores fictícios: JWKS gerado aqui e subs no formato 00000000-…
const ISSUER = 'http://localhost:8180/realms/safetycar-dev';
const AUDIENCE = 'safetycar-api';
const CLIENT = 'safetycar-web';

const sub = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const SUB_TOMADOR = sub(1);
const SUB_PARCEIRO = sub(2);
const SUB_CENTRAL = sub(3);
const SUB_PENDENTE = sub(4);
const SUB_SUSPENSO = sub(5);
const SUB_BLOQUEADO = sub(6);
const SUB_EXCLUIDO = sub(7);
const SUB_SEM_REGISTRO = sub(9);

const USUARIOS = new Map<string, Acesso>([
  [SUB_TOMADOR, { perfil: 'tomador', status: 'ativo' }],
  [SUB_PARCEIRO, { perfil: 'parceiro', status: 'ativo' }],
  [SUB_CENTRAL, { perfil: 'central', status: 'ativo' }],
  [SUB_PENDENTE, { perfil: 'parceiro', status: 'pendente' }],
  [SUB_SUSPENSO, { perfil: 'tomador', status: 'suspenso' }],
  [SUB_BLOQUEADO, { perfil: 'parceiro', status: 'bloqueado' }],
  [SUB_EXCLUIDO, { perfil: 'central', status: 'excluido' }],
]);

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

/** Token no formato do Keycloak (typ Bearer, iss do realm, aud com safetycar-api, azp do web). */
async function token(opcoes: OpcoesToken = {}): Promise<string> {
  const agora = Math.floor(Date.now() / 1000);
  const exp = typeof opcoes.expiraEm === 'number' ? opcoes.expiraEm : agora + 300;
  // As claims do teste vêm por último: sobrescrevem as padrão (iss, aud, sub etc.).
  return new SignJWT({
    typ: 'Bearer',
    azp: CLIENT,
    iss: ISSUER,
    aud: [AUDIENCE, 'account'],
    sub: SUB_TOMADOR,
    iat: agora,
    exp,
    ...opcoes.claims,
  })
    .setProtectedHeader({ alg: 'RS256', kid: 'chave-teste', typ: 'JWT' })
    .sign(opcoes.chave ?? chavePrivada);
}

interface OpcoesMontagem {
  chaves?: JWTVerifyGetKey;
  banco?: Banco;
}

const apps: ReturnType<typeof construirApp>[] = [];
after(async () => {
  await Promise.all(apps.map((app) => app.close()));
});

async function getMe(autorizacao?: string, opcoes: OpcoesMontagem = {}) {
  const log = new LogCapturado();
  const app = construirApp({
    banco: opcoes.banco ?? bancoFalso(() => Promise.resolve(), USUARIOS),
    verificadorToken: criarVerificadorKeycloak({
      issuer: ISSUER,
      audience: AUDIENCE,
      azp: CLIENT,
      chaves: opcoes.chaves ?? chavesPublicas,
    }),
    nivelLog: 'trace',
    destinoLog: log,
  });
  apps.push(app);
  const resposta = await app.inject({
    method: 'GET',
    url: '/me',
    headers: autorizacao === undefined ? {} : { authorization: autorizacao },
  });
  return { resposta, log };
}

const codigoErro = (resposta: { body: string }) =>
  (JSON.parse(resposta.body) as { erro: { codigo: string } }).erro.codigo;

async function esperar401(autorizacao: string | undefined, codigo: string) {
  const { resposta } = await getMe(autorizacao);
  assert.equal(resposta.statusCode, 401);
  assert.equal(codigoErro(resposta), codigo);
  assert.match(String(resposta.headers['www-authenticate']), /^Bearer realm="safetycar"/);
}

describe('GET /me: validação do token', () => {
  test('aceita o esquema "bearer" em minúsculas', async () => {
    const { resposta } = await getMe(`bearer ${await token()}`);
    assert.equal(resposta.statusCode, 200);
  });

  test('401 sem cabeçalho Authorization', async () => {
    await esperar401(undefined, 'nao_autenticado');
  });

  test('401 com outro esquema (Basic)', async () => {
    await esperar401('Basic dXN1YXJpbzpzZW5oYQ==', 'nao_autenticado');
  });

  test('401 com token expirado', async () => {
    const t = await token({ expiraEm: Math.floor(Date.now() / 1000) - 60 });
    await esperar401(`Bearer ${t}`, 'token_invalido');
  });

  test('401 com emissor diferente', async () => {
    const t = await token({ claims: { iss: 'http://localhost:8180/realms/master' } });
    await esperar401(`Bearer ${t}`, 'token_invalido');
  });

  test('401 sem a audiência safetycar-api', async () => {
    await esperar401(`Bearer ${await token({ claims: { aud: 'account' } })}`, 'token_invalido');
  });

  test('401 com azp de outro client', async () => {
    await esperar401(
      `Bearer ${await token({ claims: { azp: 'outro-client' } })}`,
      'token_invalido',
    );
  });

  test('401 sem azp', async () => {
    await esperar401(`Bearer ${await token({ claims: { azp: undefined } })}`, 'token_invalido');
  });

  test('401 com assinatura de outra chave', async () => {
    await esperar401(`Bearer ${await token({ chave: outraChavePrivada })}`, 'token_invalido');
  });

  test('401 com "alg: none" (token sem assinatura)', async () => {
    const corpo = {
      iss: ISSUER,
      aud: AUDIENCE,
      azp: CLIENT,
      sub: SUB_TOMADOR,
      typ: 'Bearer',
      exp: 9999999999,
      iat: 1,
    };
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
    const { resposta } = await getMe(`Bearer ${await token()}`, { chaves: indisponivel });
    assert.equal(resposta.statusCode, 503);
    assert.equal(codigoErro(resposta), 'autenticacao_indisponivel');
  });

  test('o perfil vem do banco, não do token', async () => {
    // Claims inventadas no token não mudam nada: o tomador continua tomador.
    const t = await token({
      claims: { perfil: 'central', realm_access: { roles: ['central'] } },
    });
    const { resposta } = await getMe(`Bearer ${t}`);
    assert.deepEqual(resposta.json(), { perfil: 'tomador', status: 'ativo' });
  });
});

describe('GET /me: perfil e status', () => {
  for (const [nome, s, perfil] of [
    ['tomador', SUB_TOMADOR, 'tomador'],
    ['parceiro', SUB_PARCEIRO, 'parceiro'],
    ['central', SUB_CENTRAL, 'central'],
  ] as const) {
    test(`200 para ${nome} ativo: só perfil e status`, async () => {
      const { resposta } = await getMe(`Bearer ${await token({ claims: { sub: s } })}`);
      assert.equal(resposta.statusCode, 200);
      assert.deepEqual(resposta.json(), { perfil, status: 'ativo' });
      assert.equal(resposta.headers['cache-control'], 'no-store');
    });
  }

  test('200 para usuário pendente, com status "pendente"', async () => {
    const { resposta } = await getMe(`Bearer ${await token({ claims: { sub: SUB_PENDENTE } })}`);
    assert.equal(resposta.statusCode, 200);
    assert.deepEqual(resposta.json(), { perfil: 'parceiro', status: 'pendente' });
    assert.equal(resposta.headers['cache-control'], 'no-store');
  });

  test('sem registro, suspenso, bloqueado e excluído: a mesma resposta 403', async () => {
    const respostas = [];
    for (const s of [SUB_SEM_REGISTRO, SUB_SUSPENSO, SUB_BLOQUEADO, SUB_EXCLUIDO]) {
      const { resposta } = await getMe(`Bearer ${await token({ claims: { sub: s } })}`);
      assert.equal(resposta.statusCode, 403);
      assert.equal(resposta.headers['cache-control'], 'no-store');
      respostas.push(resposta.body);
    }
    // Corpo idêntico: não dá para saber se a conta existe nem qual é o status.
    assert.equal(new Set(respostas).size, 1);
    assert.deepEqual(JSON.parse(respostas[0] ?? ''), {
      erro: { codigo: 'acesso_restrito', mensagem: 'Acesso restrito.' },
    });
  });

  test('503 sem detalhes quando o banco falha na consulta', async () => {
    const banco = bancoFalso(
      () => Promise.resolve(),
      undefined,
      () => Promise.reject(new Error('connect ECONNREFUSED')),
    );
    const { resposta, log } = await getMe(`Bearer ${await token()}`, { banco });
    assert.equal(resposta.statusCode, 503);
    assert.equal(codigoErro(resposta), 'servico_indisponivel');
    assert.ok(!resposta.body.includes('ECONNREFUSED'));
    assert.match(log.texto, /falha ao consultar o usuário/);
  });

  test('o log não contém o token nem o sub (aceito, restrito e recusado)', async () => {
    const t = await token();
    const tRestrito = await token({ claims: { sub: SUB_SUSPENSO } });
    const { log } = await getMe(`Bearer ${t}`);
    const { log: logRestrito } = await getMe(`Bearer ${tRestrito}`);
    const { log: logRecusa } = await getMe(`Bearer ${await token({ chave: outraChavePrivada })}`);
    for (const texto of [log.texto, logRestrito.texto, logRecusa.texto]) {
      for (const s of [SUB_TOMADOR, SUB_SUSPENSO]) {
        assert.ok(!texto.includes(s), 'o log contém o sub');
      }
      for (const tk of [t, tRestrito]) {
        assert.ok(!texto.includes(tk.split('.')[1] ?? tk), 'o log contém o token');
      }
    }
    assert.match(log.texto, /"rota":"\/me","status":200/);
    assert.match(logRestrito.texto, /"rota":"\/me","status":403/);
  });

  test('a rota antiga /eu não existe mais', async () => {
    const log = new LogCapturado();
    const app = construirApp({
      banco: bancoFalso(() => Promise.resolve()),
      verificadorToken: criarVerificadorKeycloak({
        issuer: ISSUER,
        audience: AUDIENCE,
        azp: CLIENT,
        chaves: chavesPublicas,
      }),
      nivelLog: 'silent',
      destinoLog: log,
    });
    apps.push(app);
    const resposta = await app.inject({
      method: 'GET',
      url: '/eu',
      headers: { authorization: `Bearer ${await token()}` },
    });
    assert.equal(resposta.statusCode, 404);
  });
});
