import { Outlet } from 'react-router';
import { LinkPularConteudo } from './LinkPularConteudo.tsx';
import { Marca } from './Marca.tsx';

/** Coluna de no máximo 390 px com cabeçalho do logotipo (tomador e parceiro). */
export function LayoutMovel() {
  return (
    <div className="min-h-dvh font-sans">
      <LinkPularConteudo />
      <header className="fundo-escuro bg-marinho">
        <div className="mx-auto w-full max-w-[390px] px-4 py-2">
          <Marca />
        </div>
      </header>
      <main
        id="conteudo"
        tabIndex={-1}
        className="mx-auto flex w-full max-w-[390px] flex-col gap-4 px-4 py-6"
      >
        <Outlet />
      </main>
    </div>
  );
}
