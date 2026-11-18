import { Link } from 'react-router';
import logotipo from '../assets/logotipo-96.png';

/** Logotipo e nome, com link para a página inicial. Usado sobre o azul-marinho. */
export function Marca() {
  return (
    <Link
      to="/"
      className="inline-flex min-h-11 items-center gap-3 rounded-lg text-lg font-bold tracking-wide text-branco"
    >
      <img src={logotipo} alt="" width={40} height={40} className="size-10 rounded-lg" />
      Safety Car
    </Link>
  );
}
