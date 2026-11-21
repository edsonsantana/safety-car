import { lazy, Suspense } from 'react';
import { Navigate, Route, Routes } from 'react-router';
import { RotaProtegida } from './autenticacao/RotaProtegida.tsx';
import { LayoutMovel } from './layouts/LayoutMovel.tsx';
import { LayoutPainel } from './layouts/LayoutPainel.tsx';
import { AcessoRestrito } from './paginas/AcessoRestrito.tsx';
import { Entrada } from './paginas/Entrada.tsx';
import { Entrando } from './paginas/Entrando.tsx';
import {
  Cadastro,
  Central,
  InicioParceiro,
  InicioTomador,
  NaoEncontrada,
  Verificacao,
} from './paginas/Paginas.tsx';

// Só em desenvolvimento: em produção, import.meta.env.DEV é false e o Vite
// elimina o import, então a página nem chega ao dist/ (conferido no build).
const Componentes = import.meta.env.DEV ? lazy(() => import('./paginas/Componentes.tsx')) : null;

export function Rotas() {
  return (
    <Routes>
      {/* Telas de entrada (fundo escuro, layout próprio). */}
      <Route index element={<Entrada />} />
      <Route path="entrando" element={<Entrando />} />
      <Route path="acesso-restrito" element={<AcessoRestrito />} />
      {/* O login agora é no Keycloak: o antigo /entrar leva à entrada. */}
      <Route path="entrar" element={<Navigate to="/" replace />} />

      <Route element={<RotaProtegida perfis={['tomador']} />}>
        <Route element={<LayoutMovel />}>
          <Route path="tomador" element={<InicioTomador />} />
        </Route>
      </Route>
      <Route element={<RotaProtegida perfis={['parceiro']} />}>
        <Route element={<LayoutMovel />}>
          <Route path="parceiro" element={<InicioParceiro />} />
        </Route>
      </Route>
      <Route element={<RotaProtegida perfis={['central']} />}>
        <Route path="central" element={<LayoutPainel />}>
          <Route index element={<Central />} />
        </Route>
      </Route>

      <Route element={<LayoutMovel />}>
        <Route path="cadastro" element={<Cadastro />} />
        <Route path="verificacao" element={<Verificacao />} />
        {Componentes && (
          <Route
            path="componentes"
            element={
              <Suspense fallback={null}>
                <Componentes />
              </Suspense>
            }
          />
        )}
        <Route path="*" element={<NaoEncontrada />} />
      </Route>
    </Routes>
  );
}
