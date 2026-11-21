import { z } from 'zod';

/** Papéis que a API nunca pode usar: o migrator faz DDL e o postgres é superusuário. */
const PAPEIS_PROIBIDOS = ['safetycar_migrator', 'postgres'];

const NIVEIS_LOG = ['fatal', 'error', 'warn', 'info', 'debug', 'trace', 'silent'] as const;

const texto = (padrao?: string) => {
  const base = z.string({
    error: (problema) => (problema.input === undefined ? 'obrigatória' : 'deve ser texto'),
  });
  return padrao === undefined ? base.min(1, 'obrigatória') : base.min(1).default(padrao);
};

const porta = (padrao: number) =>
  z.coerce
    .number({ error: 'deve ser um número' })
    .int('deve ser um número inteiro')
    .min(1, 'deve estar entre 1 e 65535')
    .max(65535, 'deve estar entre 1 e 65535')
    .default(padrao);

const esquema = z.object({
  API_HOST: texto('127.0.0.1'),
  API_PORTA: porta(3000),
  API_LOG_NIVEL: z
    .enum(NIVEIS_LOG, { error: `deve ser um de: ${NIVEIS_LOG.join(', ')}` })
    .default('info'),

  API_DB_HOST: texto('127.0.0.1'),
  API_DB_PORTA: porta(5432),
  API_DB_NOME: texto('safetycar'),
  API_DB_USUARIO: texto('safetycar_app').refine((papel) => !PAPEIS_PROIBIDOS.includes(papel), {
    message: `use o papel safetycar_app; ${PAPEIS_PROIBIDOS.join(' e ')} são proibidos na API`,
  }),
  API_DB_SENHA: texto(),

  // Realm do Keycloak cujos tokens a API aceita (o "iss" do token deve ser exatamente este).
  KEYCLOAK_ISSUER: texto()
    .refine((valor) => URL.canParse(valor) && /^https?:$/.test(new URL(valor).protocol), {
      message: 'deve ser uma URL http(s), ex.: http://localhost:8180/realms/safetycar-dev',
    })
    .transform((valor) => valor.replace(/\/+$/, '')),
  KEYCLOAK_AUDIENCE: texto('safetycar-api'),
  // Client do frontend: o "azp" do token precisa ser este (token emitido para o nosso app).
  KEYCLOAK_CLIENT_ID: texto('safetycar-web'),
});

export interface Config {
  readonly http: { readonly host: string; readonly porta: number };
  readonly log: { readonly nivel: (typeof NIVEIS_LOG)[number] };
  readonly banco: {
    readonly host: string;
    readonly porta: number;
    readonly nome: string;
    readonly usuario: string;
    readonly senha: string;
  };
  readonly keycloak: {
    readonly issuer: string;
    readonly audience: string;
    /** Valor exigido no "azp" do token. */
    readonly azp: string;
  };
}

/** Configuração inválida. A mensagem lista as variáveis e o motivo, nunca o valor. */
export class ErroConfiguracao extends Error {
  readonly problemas: readonly string[];

  constructor(problemas: readonly string[]) {
    super(
      `Configuração inválida da API. Corrija as variáveis de ambiente (veja o .env.example):\n` +
        problemas.map((p) => `  - ${p}`).join('\n'),
    );
    this.name = 'ErroConfiguracao';
    this.problemas = problemas;
  }
}

/** Lê e valida a configuração. Variável vazia conta como ausente. */
export function carregarConfig(ambiente: NodeJS.ProcessEnv = process.env): Config {
  const entrada: Record<string, string> = {};
  for (const chave of Object.keys(esquema.shape)) {
    const valor = ambiente[chave];
    if (valor !== undefined && valor.trim() !== '') entrada[chave] = valor;
  }

  const resultado = esquema.safeParse(entrada);
  if (!resultado.success) {
    throw new ErroConfiguracao(
      resultado.error.issues.map((problema) => `${problema.path.join('.')}: ${problema.message}`),
    );
  }

  const v = resultado.data;
  return {
    http: { host: v.API_HOST, porta: v.API_PORTA },
    log: { nivel: v.API_LOG_NIVEL },
    banco: {
      host: v.API_DB_HOST,
      porta: v.API_DB_PORTA,
      nome: v.API_DB_NOME,
      usuario: v.API_DB_USUARIO,
      senha: v.API_DB_SENHA,
    },
    keycloak: {
      issuer: v.KEYCLOAK_ISSUER,
      audience: v.KEYCLOAK_AUDIENCE,
      azp: v.KEYCLOAK_CLIENT_ID,
    },
  };
}
