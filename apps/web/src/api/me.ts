import type { Acesso, Perfil } from '../autenticacao/tipos.ts';
import { API_BASE } from './config.ts';

const PERFIS: readonly string[] = ['tomador', 'parceiro', 'central'] satisfies Perfil[];
const TEMPO_LIMITE_PADRAO_MS = 5000;

interface Opcoes {
  sinal?: AbortSignal;
  tempoLimiteMs?: number;
}

/**
 * Consulta GET /me com o token de acesso.
 * - 200 { perfil, status: "ativo" }: liberado.
 * - 200 { perfil, status: "pendente" }: pendente.
 * - 403: restrito (sem registro, suspenso, bloqueado ou excluído; a API não diz qual).
 * - Qualquer outra coisa (401, 503, rede, resposta fora do formato): indisponível. O 401
 *   não volta para "anônimo" de propósito, para não entrar num ciclo de logins.
 */
export async function consultarMe(
  token: string,
  { sinal, tempoLimiteMs = TEMPO_LIMITE_PADRAO_MS }: Opcoes = {},
): Promise<Acesso> {
  const tempo = AbortSignal.timeout(tempoLimiteMs);
  const signal = sinal ? AbortSignal.any([sinal, tempo]) : tempo;

  let resposta: Response;
  try {
    resposta = await fetch(`${API_BASE}/me`, {
      signal,
      cache: 'no-store',
      headers: { accept: 'application/json', authorization: `Bearer ${token}` },
    });
  } catch (erro) {
    if (sinal?.aborted) throw erro;
    return { tipo: 'indisponivel' };
  }

  if (resposta.status === 403) return { tipo: 'restrito' };
  if (resposta.status !== 200) return { tipo: 'indisponivel' };

  let corpo: unknown;
  try {
    corpo = await resposta.json();
  } catch {
    return { tipo: 'indisponivel' };
  }
  if (typeof corpo !== 'object' || corpo === null) return { tipo: 'indisponivel' };
  const { perfil, status } = corpo as Record<string, unknown>;
  if (typeof perfil !== 'string' || !PERFIS.includes(perfil)) return { tipo: 'indisponivel' };
  const p = perfil as Perfil;
  if (status === 'ativo') return { tipo: 'liberado', perfil: p };
  if (status === 'pendente') return { tipo: 'pendente', perfil: p };
  return { tipo: 'indisponivel' };
}
