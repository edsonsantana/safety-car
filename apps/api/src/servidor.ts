// Ponto de entrada: valida a configuração, confere o papel do banco e sobe o HTTP.
import { construirApp } from './app.ts';
import { criarBanco, criarPool, ErroPapelBanco, verificarPapel } from './banco.ts';
import { carregarConfig, ErroConfiguracao } from './config.ts';

function falhar(mensagem: string): never {
  process.stderr.write(`\n${mensagem}\n\n`);
  process.exit(1);
}

async function iniciar(): Promise<void> {
  let config;
  try {
    config = carregarConfig();
  } catch (erro) {
    if (erro instanceof ErroConfiguracao) falhar(erro.message);
    throw erro;
  }

  const pool = criarPool(config.banco);
  const destinoBanco = `${config.banco.host}:${String(config.banco.porta)}/${config.banco.nome}`;
  try {
    await verificarPapel(pool);
  } catch (erro) {
    await pool.end().catch(() => undefined);
    if (erro instanceof ErroPapelBanco) falhar(`Papel do banco recusado: ${erro.message}.`);
    const motivo = erro instanceof Error ? erro.message : String(erro);
    falhar(
      `Não foi possível conectar ao banco em ${destinoBanco} como ${config.banco.usuario}: ${motivo}\n` +
        `Confira se o banco está no ar (docker compose up -d) e as variáveis API_DB_* do .env.`,
    );
  }

  const banco = criarBanco(pool);
  const app = construirApp({ banco, nivelLog: config.log.nivel });

  pool.on('error', (erro) => {
    app.log.error({ err: erro }, 'erro em conexão ociosa do banco');
  });

  let encerrando = false;
  const encerrar = (sinal: string) => {
    if (encerrando) return;
    encerrando = true;
    app.log.info({ sinal }, 'encerrando');
    app
      .close()
      .then(() => banco.encerrar())
      .then(() => process.exit(0))
      .catch((erro: unknown) => {
        app.log.error({ err: erro }, 'falha ao encerrar');
        process.exit(1);
      });
  };
  process.on('SIGINT', encerrar);
  process.on('SIGTERM', encerrar);

  await app.listen({ host: config.http.host, port: config.http.porta });
  app.log.info({ banco: destinoBanco }, 'API no ar');
}

await iniciar();
