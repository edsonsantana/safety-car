import { Writable } from 'node:stream';

import type { VerificadorToken } from '../src/autenticacao.ts';
import type { Acesso, Banco } from '../src/banco.ts';

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

/**
 * Banco falso: o teste escolhe o ping e, se quiser, os usuários (keycloak_sub → acesso).
 * buscarAcesso também pode ser trocado por inteiro (para simular falha).
 */
export function bancoFalso(
  ping: () => Promise<void>,
  usuarios: ReadonlyMap<string, Acesso> = new Map(),
  buscarAcesso?: Banco['buscarAcesso'],
): Banco {
  return {
    ping,
    buscarAcesso: buscarAcesso ?? ((sub) => Promise.resolve(usuarios.get(sub))),
    encerrar: () => Promise.resolve(),
  };
}

export const bancoOk = (): Banco => bancoFalso(() => Promise.resolve());

/** Verificador que recusa tudo: para testes que não tratam de autenticação. */
export const verificadorRecusaTudo: VerificadorToken = {
  verificar: () => Promise.reject(new Error('não usado neste teste')),
};
