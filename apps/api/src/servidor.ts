// Ponto de entrada: valida a configuração, confere os papéis do banco e sobe o HTTP.
import type pg from 'pg';

import { construirApp } from './app.ts';
import { criarChavesKeycloak, criarVerificadorKeycloak } from './autenticacao.ts';
import { criarBanco, criarPool, ErroPapelBanco, verificarPapel } from './banco.ts';
import { criarBancoCentral, criarPoolCentral, verificarPapelCentral } from './central/banco.ts';
import { carregarConfig, ErroConfiguracao } from './config.ts';

function falhar(mensagem: string): never {
  process.stderr.write(`\n${mensagem}\n\n`);
  process.exit(1);
}

async function conferirPapel(
  pool: pg.Pool,
  verificar: (pool: pg.Pool) => Promise<string>,
  destino: string,
  papel: string,
  variaveis: string,
): Promise<void> {
  try {
    await verificar(pool);
  } catch (erro) {
    await pool.end().catch(() => undefined);
    if (erro instanceof ErroPapelBanco) falhar(`Papel do banco recusado: ${erro.message}.`);
    const motivo = erro instanceof Error ? erro.message : String(erro);
    falhar(
      `Não foi possível conectar ao banco em ${destino} como ${papel}: ${motivo}\n` +
        `Confira se o banco está no ar (docker compose up -d) e as variáveis ${variaveis} do .env.`,
    );
  }
}

async function iniciar(): Promise<void> {
  let config;
  try {
    config = carregarConfig();
  } catch (erro) {
    if (erro instanceof ErroConfiguracao) falhar(erro.message);
    throw erro;
  }

  const destinoBanco = `${config.banco.host}:${String(config.banco.porta)}/${config.banco.nome}`;
  const pool = criarPool(config.banco);
  await conferirPapel(pool, verificarPapel, destinoBanco, config.banco.usuario, 'API_DB_*');
  const poolCentral = criarPoolCentral(config.central.banco);
  await conferirPapel(
    poolCentral,
    verificarPapelCentral,
    destinoBanco,
    config.central.banco.usuario,
    'API_CENTRAL_DB_*',
  );

  const banco = criarBanco(pool);
  const bancoCentral = criarBancoCentral(poolCentral, () => poolCentral.end());
  // Um só JWKS para os dois verificadores (app e Central); o azp é o que os separa.
  const chaves = criarChavesKeycloak(config.keycloak.issuer);
  const verificadorToken = criarVerificadorKeycloak({ ...config.keycloak, chaves });
  const verificadorCentral = criarVerificadorKeycloak({
    issuer: config.keycloak.issuer,
    audience: config.keycloak.audience,
    azp: config.central.azp,
    chaves,
  });
  const app = construirApp({
    banco,
    verificadorToken,
    nivelLog: config.log.nivel,
    central: {
      banco: bancoCentral,
      verificador: verificadorCentral,
      acr: config.central.acr,
      otpRecenteSegundos: config.central.otpRecenteSegundos,
    },
  });

  pool.on('error', (erro) => {
    app.log.error({ err: erro }, 'erro em conexão ociosa do banco');
  });
  poolCentral.on('error', (erro) => {
    app.log.error({ err: erro }, 'erro em conexão ociosa do banco da Central');
  });

  let encerrando = false;
  const encerrar = (sinal: string) => {
    if (encerrando) return;
    encerrando = true;
    app.log.info({ sinal }, 'encerrando');
    app
      .close()
      .then(() => Promise.all([banco.encerrar(), bancoCentral.encerrar()]))
      .then(() => process.exit(0))
      .catch((erro: unknown) => {
        app.log.error({ err: erro }, 'falha ao encerrar');
        process.exit(1);
      });
  };
  process.on('SIGINT', encerrar);
  process.on('SIGTERM', encerrar);

  await app.listen({ host: config.http.host, port: config.http.porta });
  app.log.info({ banco: destinoBanco, keycloak: config.keycloak.issuer }, 'API no ar');
}

await iniciar();
