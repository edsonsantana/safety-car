import { Navigate, Outlet, useLocation } from 'react-router';
import { AcessoRestrito } from '../paginas/AcessoRestrito.tsx';
import { useSessao } from './contexto.ts';
import type { Perfil } from './tipos.ts';

interface Props {
  /** Perfis que podem abrir a área. */
  perfis: readonly Perfil[];
}

/**
 * Área por perfil. É só experiência de uso: quem protege os dados é a API, rota a rota.
 * - sem sessão: vai para a entrada, guardando o caminho de volta;
 * - perfil ativo e permitido: mostra a área;
 * - qualquer outro caso: Acesso restrito (que também mostra o carregamento e a falha).
 */
export function RotaProtegida({ perfis }: Props) {
  const { acesso } = useSessao();
  const local = useLocation();

  if (acesso.tipo === 'anonimo') {
    return <Navigate to="/" replace state={{ destino: `${local.pathname}${local.search}` }} />;
  }
  if (acesso.tipo === 'liberado' && perfis.includes(acesso.perfil)) return <Outlet />;
  return <AcessoRestrito />;
}
