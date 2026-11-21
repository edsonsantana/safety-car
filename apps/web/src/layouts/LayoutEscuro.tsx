import type { ReactNode } from 'react';
import { LinkPularConteudo } from './LinkPularConteudo.tsx';

/** Logotipo em public/ (cópia de docs/Imagens/logo-icone.png). */
export const LOGO = '/logo-icone.png';

interface Props {
  children: ReactNode;
  /** Cabeçalho com o logo pequeno (tela de entrada). */
  comCabecalho?: boolean;
}

/**
 * Telas de entrada (entrada, "Entrando…", acesso restrito): fundo escuro com os dois
 * painéis diagonais, coluna de 390 px e rodapé com os números de urgência.
 */
export function LayoutEscuro({ children, comCabecalho = false }: Props) {
  return (
    <div className="fundo-escuro fundo-diagonais flex min-h-dvh flex-col font-sans text-branco">
      <LinkPularConteudo />
      {comCabecalho && (
        <header className="mx-auto w-full max-w-[390px] px-4 pt-4">
          <img src={LOGO} alt="Safety Car" width={40} height={40} className="size-10" />
        </header>
      )}
      <main
        id="conteudo"
        tabIndex={-1}
        className="mx-auto flex w-full max-w-[390px] flex-1 flex-col items-center justify-center gap-6 px-4 py-8 text-center"
      >
        {children}
      </main>
      <footer className="mx-auto w-full max-w-[390px] px-4 pb-6 text-center text-sm text-texto-claro">
        <p>
          Em urgência:{' '}
          <a href="tel:192" className="underline underline-offset-2">
            192 (SAMU)
          </a>{' '}
          e{' '}
          <a href="tel:193" className="underline underline-offset-2">
            193 (Bombeiros)
          </a>
        </p>
      </footer>
    </div>
  );
}

/** "SAFETY CAR" em Playfair Display (o texto acessível é "Safety Car"). */
export function NomeMarca({ como: Tag = 'p' }: { como?: 'h1' | 'p' }) {
  return (
    <Tag className="font-marca text-4xl font-bold tracking-wide text-branco uppercase">
      Safety Car
    </Tag>
  );
}
