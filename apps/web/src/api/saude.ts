import { API_BASE } from './config.ts';

export type EstadoSaude = 'ok' | 'banco_indisponivel' | 'api_indisponivel';

const TEMPO_LIMITE_PADRAO_MS = 5000;

interface Opcoes {
  /** Cancela a consulta (ex.: componente desmontado). */
  sinal?: AbortSignal;
  tempoLimiteMs?: number;
}

/**
 * Consulta GET /saude da API.
 * - 200 com status "ok": API e banco respondem.
 * - 503 com banco "indisponivel": a API responde, mas o banco não.
 * - Qualquer outra coisa (rede, tempo esgotado, proxy sem a API): API indisponível.
 */
export async function consultarSaude({
  sinal,
  tempoLimiteMs = TEMPO_LIMITE_PADRAO_MS,
}: Opcoes = {}): Promise<EstadoSaude> {
  const tempo = AbortSignal.timeout(tempoLimiteMs);
  const signal = sinal ? AbortSignal.any([sinal, tempo]) : tempo;

  let resposta: Response;
  let corpo: unknown;
  try {
    resposta = await fetch(`${API_BASE}/saude`, {
      signal,
      cache: 'no-store',
      headers: { accept: 'application/json' },
    });
    corpo = await resposta.json();
  } catch (erro) {
    // Cancelamento pedido por quem chamou não é falha da API: repassa.
    if (sinal?.aborted) throw erro;
    return 'api_indisponivel';
  }

  if (resposta.status === 200 && campo(corpo, 'status') === 'ok') return 'ok';
  if (resposta.status === 503 && campo(corpo, 'banco') === 'indisponivel') {
    return 'banco_indisponivel';
  }
  return 'api_indisponivel';
}

function campo(corpo: unknown, nome: string): unknown {
  return typeof corpo === 'object' && corpo !== null && nome in corpo
    ? (corpo as Record<string, unknown>)[nome]
    : undefined;
}
