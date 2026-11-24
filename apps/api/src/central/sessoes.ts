import { criarPseudonimo } from './limite.ts';

/** Sessão máxima do realm (ssoSessionMaxLifespan = 36000 s): depois disso, o login é outro. */
const DURACAO_MAXIMA_MS = 36_000 * 1000;

/**
 * Sessões já registradas em POST /central/sessao, para ignorar a repetição do mesmo login
 * (mesmo sub + mesmo auth_time). EM MEMÓRIA: vale para uma instância; depois de reiniciar, o
 * mesmo login pode gerar um segundo central_acesso (inofensivo: só o último acesso é lido).
 * Guarda só um pseudônimo (HMAC com chave do processo), nunca o sub.
 */
export class SessoesRegistradas {
  readonly #vistas = new Map<string, number>();
  readonly #chave = criarPseudonimo();
  readonly #agora: () => number;
  readonly #maxChaves: number;

  constructor(agora: () => number = Date.now, maxChaves = 10_000) {
    this.#agora = agora;
    this.#maxChaves = maxChaves;
  }

  /**
   * true se este login ainda não foi registrado; já o marca (antes de gravar), para que duas
   * chamadas simultâneas não gravem duas vezes. Se a gravação falhar, chame desfazer().
   */
  reservar(sub: string, authTime: number): boolean {
    const agora = this.#agora();
    const chave = this.#chave(`${sub}|${String(authTime)}`);
    const expira = this.#vistas.get(chave);
    if (expira !== undefined && expira > agora) return false;
    this.#limpar(agora);
    this.#vistas.set(chave, authTime * 1000 + DURACAO_MAXIMA_MS);
    return true;
  }

  desfazer(sub: string, authTime: number): void {
    this.#vistas.delete(this.#chave(`${sub}|${String(authTime)}`));
  }

  #limpar(agora: number): void {
    if (this.#vistas.size < this.#maxChaves) return;
    for (const [chave, expira] of this.#vistas) if (expira <= agora) this.#vistas.delete(chave);
    if (this.#vistas.size < this.#maxChaves) return;
    const maisAntiga = this.#vistas.keys().next();
    if (maisAntiga.done !== true) this.#vistas.delete(maisAntiga.value);
  }
}
