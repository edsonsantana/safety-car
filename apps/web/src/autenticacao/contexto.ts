import { createContext, useContext } from 'react';
import type { Sessao } from './tipos.ts';

export const ContextoSessao = createContext<Sessao | null>(null);

/** Sessão atual. Só funciona dentro do <ProvedorSessao>. */
export function useSessao(): Sessao {
  const sessao = useContext(ContextoSessao);
  if (!sessao) throw new Error('useSessao usado fora do <ProvedorSessao>');
  return sessao;
}
