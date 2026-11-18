import { Writable } from 'node:stream';

import type { Banco } from '../src/banco.ts';

/** Destino de log em memória: guarda cada linha JSON emitida pelo pino. */
export class LogCapturado extends Writable {
  readonly linhas: string[] = [];

  override _write(pedaco: Buffer, _codificacao: string, pronto: () => void): void {
    this.linhas.push(...pedaco.toString('utf8').split('\n').filter(Boolean));
    pronto();
  }

  get texto(): string {
    return this.linhas.join('\n');
  }

  registros(): Record<string, unknown>[] {
    return this.linhas.map((linha) => JSON.parse(linha) as Record<string, unknown>);
  }
}

/** Banco falso: o comportamento do ping é escolhido pelo teste. */
export function bancoFalso(ping: () => Promise<void>): Banco {
  return { ping, encerrar: () => Promise.resolve() };
}

export const bancoOk = (): Banco => bancoFalso(() => Promise.resolve());
