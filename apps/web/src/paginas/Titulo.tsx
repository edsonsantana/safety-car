interface Props {
  /** Texto do <h1>; também compõe o document.title ("Cadastro · Safety Car"). */
  children: string;
}

/** <h1> da página e título da aba (o React 19 leva o <title> para o <head>). */
export function Titulo({ children }: Props) {
  return (
    <>
      <title>{`${children} · Safety Car`}</title>
      <h1 className="text-2xl font-bold text-marinho">{children}</h1>
    </>
  );
}
