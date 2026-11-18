import { lazy, Suspense } from 'react';
import { Route, Routes } from 'react-router';
import { LayoutMovel } from './layouts/LayoutMovel.tsx';
import { LayoutPainel } from './layouts/LayoutPainel.tsx';
import { Inicio } from './paginas/Inicio.tsx';
import { Cadastro, Central, Entrar, NaoEncontrada, Verificacao } from './paginas/Paginas.tsx';

// Só em desenvolvimento: em produção, import.meta.env.DEV é false e o Vite
// elimina o import, então a página nem chega ao dist/ (conferido no build).
const Componentes = import.meta.env.DEV ? lazy(() => import('./paginas/Componentes.tsx')) : null;

export function Rotas() {
  return (
    <Routes>
      <Route element={<LayoutMovel />}>
        <Route index element={<Inicio />} />
        <Route path="cadastro" element={<Cadastro />} />
        <Route path="entrar" element={<Entrar />} />
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
      <Route path="central" element={<LayoutPainel />}>
        <Route index element={<Central />} />
      </Route>
    </Routes>
  );
}
