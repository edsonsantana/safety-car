import { z } from 'zod';

/** Papéis que a API nunca pode usar: o migrator faz DDL e o postgres é superusuário. */
const PAPEIS_PROIBIDOS = ['safetycar_migrator', 'postgres'];

/** Papel do pool da Central (0014): executa as funções sensíveis; o app nunca o usa. */
const PAPEL_CENTRAL = 'safetycar_central';
const PAPEL_APP = 'safetycar_app';

/** OTP recente para ação sensível: auth_time de até 10 minutos (decidido). */
export const OTP_RECENTE_SEGUNDOS = 600;

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

const esquema = z
  .object({
    API_HOST: texto('127.0.0.1'),
    API_PORTA: porta(3000),
    API_LOG_NIVEL: z
      .enum(NIVEIS_LOG, { error: `deve ser um de: ${NIVEIS_LOG.join(', ')}` })
      .default('info'),

    API_DB_HOST: texto('127.0.0.1'),
    API_DB_PORTA: porta(5432),
    API_DB_NOME: texto('safetycar'),
    API_DB_USUARIO: texto(PAPEL_APP).refine(
      (papel) => ![...PAPEIS_PROIBIDOS, PAPEL_CENTRAL].includes(papel),
      {
        message: `use o papel ${PAPEL_APP}; ${[...PAPEIS_PROIBIDOS, PAPEL_CENTRAL].join(', ')} são proibidos no pool do app`,
      },
    ),
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

    // --- Central (pool próprio; mesmo host, porta e banco do app) ---
    API_CENTRAL_DB_USUARIO: texto(PAPEL_CENTRAL).refine((papel) => papel === PAPEL_CENTRAL, {
      message: `use o papel ${PAPEL_CENTRAL}; o pool da Central não aceita outro papel`,
    }),
    // Mesmo valor de SAFETYCAR_CENTRAL_PASSWORD.
    API_CENTRAL_DB_SENHA: texto(),
    // Client da Central no Keycloak: o "azp" dos tokens aceitos em /central.
    KEYCLOAK_CENTRAL_CLIENT_ID: texto('safetycar-central'),
    // Valor exato do "acr" do nível 2 (senha + OTP). Confirmado com token real na etapa do realm.
    KEYCLOAK_CENTRAL_ACR: texto('2'),
  })
  .superRefine((v, ctx) => {
    if (v.KEYCLOAK_CENTRAL_CLIENT_ID === v.KEYCLOAK_CLIENT_ID) {
      ctx.addIssue({
        code: 'custom',
        path: ['KEYCLOAK_CENTRAL_CLIENT_ID'],
        message: 'deve ser diferente de KEYCLOAK_CLIENT_ID (token do app não entra na Central)',
      });
    }
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
  readonly central: {
    readonly banco: Config['banco'];
    /** Valor exigido no "azp" dos tokens de /central. */
    readonly azp: string;
    /** Único "acr" aceito em /central (nível 2: senha + OTP). */
    readonly acr: string;
    /** Idade máxima do auth_time nas ações sensíveis. */
    readonly otpRecenteSegundos: number;
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
  const destino = { host: v.API_DB_HOST, porta: v.API_DB_PORTA, nome: v.API_DB_NOME };
  return {
    http: { host: v.API_HOST, porta: v.API_PORTA },
    log: { nivel: v.API_LOG_NIVEL },
    banco: { ...destino, usuario: v.API_DB_USUARIO, senha: v.API_DB_SENHA },
    keycloak: {
      issuer: v.KEYCLOAK_ISSUER,
      audience: v.KEYCLOAK_AUDIENCE,
      azp: v.KEYCLOAK_CLIENT_ID,
    },
    central: {
      banco: { ...destino, usuario: v.API_CENTRAL_DB_USUARIO, senha: v.API_CENTRAL_DB_SENHA },
      azp: v.KEYCLOAK_CENTRAL_CLIENT_ID,
      acr: v.KEYCLOAK_CENTRAL_ACR,
      otpRecenteSegundos: OTP_RECENTE_SEGUNDOS,
    },
  };
}
