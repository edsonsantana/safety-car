/** Primeiro item focável da página: leva direto ao <main id="conteudo">. */
export function LinkPularConteudo() {
  return (
    <a
      href="#conteudo"
      className="sr-only rounded-lg bg-limao px-4 py-3 font-bold text-marinho focus:not-sr-only focus:fixed focus:top-2 focus:left-2 focus:z-50"
    >
      Pular para o conteúdo
    </a>
  );
}
