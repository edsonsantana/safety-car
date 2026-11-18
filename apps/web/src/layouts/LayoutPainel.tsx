import { useEffect, useState } from 'react';
import { NavLink, Outlet } from 'react-router';
import { classes } from '../componentes/classes.ts';
import { LinkPularConteudo } from './LinkPularConteudo.tsx';
import { Marca } from './Marca.tsx';

// Um único item até as telas da Central serem definidas.
const itensMenu = [{ para: '/central', texto: 'Painel' }] as const;

/** Painel da Central: menu lateral que vira gaveta em tela estreita. */
export function LayoutPainel() {
  const [menuAberto, setMenuAberto] = useState(false);
  // Esc fecha a gaveta.
  useEffect(() => {
    if (!menuAberto) return;
    function aoTeclar(evento: KeyboardEvent) {
      if (evento.key === 'Escape') setMenuAberto(false);
    }
    document.addEventListener('keydown', aoTeclar);
    return () => {
      document.removeEventListener('keydown', aoTeclar);
    };
  }, [menuAberto]);

  return (
    <div className="min-h-dvh font-sans">
      <LinkPularConteudo />
      <header className="fundo-escuro flex items-center gap-2 bg-marinho px-4 py-2">
        <button
          type="button"
          aria-expanded={menuAberto}
          aria-controls="menu-central"
          onClick={() => {
            setMenuAberto((aberto) => !aberto);
          }}
          className="inline-flex min-h-11 min-w-11 items-center justify-center rounded-lg text-2xl text-branco md:hidden"
        >
          <span aria-hidden="true">{menuAberto ? '✕' : '☰'}</span>
          <span className="sr-only">{menuAberto ? 'Fechar menu' : 'Abrir menu'}</span>
        </button>
        <Marca />
      </header>
      <div className="md:flex">
        <nav
          id="menu-central"
          aria-label="Menu da Central"
          className={classes(
            'fundo-escuro w-64 shrink-0 bg-marinho p-3 md:block md:min-h-[calc(100dvh-60px)]',
            menuAberto ? 'fixed inset-y-0 left-0 z-40 block pt-16' : 'hidden',
          )}
        >
          <ul className="flex flex-col gap-1">
            {itensMenu.map((item) => (
              <li key={item.para}>
                <NavLink
                  to={item.para}
                  end
                  onClick={() => {
                    setMenuAberto(false);
                  }}
                  className={({ isActive }) =>
                    classes(
                      'flex min-h-11 items-center rounded-lg px-3 font-semibold',
                      isActive ? 'bg-branco/10 text-limao' : 'text-branco',
                    )
                  }
                >
                  {item.texto}
                </NavLink>
              </li>
            ))}
          </ul>
        </nav>
        <main id="conteudo" tabIndex={-1} className="flex min-w-0 flex-1 flex-col gap-4 p-6">
          <Outlet />
        </main>
      </div>
    </div>
  );
}
