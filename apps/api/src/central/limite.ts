import { createHmac, randomBytes } from 'node:crypto';

/**
 * Limite de requisições em janela fixa, EM MEMÓRIA.
 *
 * Vale para UMA instância da API: com duas ou mais instâncias (ou depois de reiniciar), cada uma
 * conta à parte. Quando houver mais de uma instância, o limite tem de ir para um armazenamento
 * compartilhado (ou para o proxy reverso).
 *
 * O número de chaves guardadas é limitado: ao passar do máximo, as janelas vencidas saem e, se
 * ainda faltar espaço, sai a chave mais antiga.
 */
export class LimiteJanela {
  readonly #contagens = new Map<string, { inicio: number; total: number }>();
  readonly #maximo: number;
  readonly #janelaMs: number;
  readonly #agora: () => number;
  readonly #maxChaves: number;

  constructor(
    maximo: number,
    janelaMs: number,
    agora: () => number = Date.now,
    maxChaves = 10_000,
  ) {
    this.#maximo = maximo;
    this.#janelaMs = janelaMs;
    this.#agora = agora;
    this.#maxChaves = maxChaves;
  }

  /** Conta uma ocorrência. Devolve 0 se coube, ou os segundos até a janela abrir de novo. */
  consumir(chave: string): number {
    const agora = this.#agora();
    const atual = this.#contagens.get(chave);
    if (atual === undefined || agora - atual.inicio >= this.#janelaMs) {
      if (atual === undefined) this.#abrirEspaco(agora);
      this.#contagens.set(chave, { inicio: agora, total: 1 });
      return 0;
    }
    if (atual.total >= this.#maximo) return this.#espera(atual.inicio, agora);
    atual.total += 1;
    return 0;
  }

  /** Só consulta: 0 se ainda cabe, ou os segundos de espera se o limite já foi atingido. */
  excedido(chave: string): number {
    const agora = this.#agora();
    const atual = this.#contagens.get(chave);
    if (atual === undefined || agora - atual.inicio >= this.#janelaMs) return 0;
    return atual.total >= this.#maximo ? this.#espera(atual.inicio, agora) : 0;
  }

  get tamanho(): number {
    return this.#contagens.size;
  }

  #espera(inicio: number, agora: number): number {
    return Math.max(1, Math.ceil((inicio + this.#janelaMs - agora) / 1000));
  }

  #abrirEspaco(agora: number): void {
    if (this.#contagens.size < this.#maxChaves) return;
    for (const [chave, { inicio }] of this.#contagens) {
      if (agora - inicio >= this.#janelaMs) this.#contagens.delete(chave);
    }
    if (this.#contagens.size < this.#maxChaves) return;
    const maisAntiga = this.#contagens.keys().next();
    if (maisAntiga.done !== true) this.#contagens.delete(maisAntiga.value);
  }
}

export interface Limites {
  /** Por ator, GET. */
  leitura: LimiteJanela;
  /** Por ator, demais métodos. */
  escrita: LimiteJanela;
  /** Por IP (pseudonimizado): respostas 401 e 403. Atingido, o IP recebe 429 antes do token. */
  falhas: LimiteJanela;
}

export const LIMITES_PADRAO = {
  leituraPorMinuto: 120,
  escritaPorMinuto: 20,
  falhasPorMinuto: 30,
} as const;

export function criarLimites(
  agora: () => number = Date.now,
  valores: {
    leituraPorMinuto: number;
    escritaPorMinuto: number;
    falhasPorMinuto: number;
  } = LIMITES_PADRAO,
): Limites {
  return {
    leitura: new LimiteJanela(valores.leituraPorMinuto, 60_000, agora),
    escrita: new LimiteJanela(valores.escritaPorMinuto, 60_000, agora),
    falhas: new LimiteJanela(valores.falhasPorMinuto, 60_000, agora),
  };
}

/**
 * Pseudônimo de um valor (IP, sub) com chave aleatória do processo: serve de chave em memória
 * sem guardar o valor. Muda a cada subida; nunca vai para o log.
 */
export function criarPseudonimo(): (valor: string) => string {
  const segredo = randomBytes(32);
  return (valor) => createHmac('sha256', segredo).update(valor).digest('base64url');
}
