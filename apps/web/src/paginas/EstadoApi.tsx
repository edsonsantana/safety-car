import { useEffect, useState } from 'react';
import { consultarSaude, type EstadoSaude } from '../api/saude.ts';
import { CartaoAviso } from '../componentes/CartaoAviso.tsx';

type Estado = EstadoSaude | 'verificando';

const mensagens = {
  verificando: { variante: 'info', texto: 'Verificando a conexão com o servidor…' },
  ok: { variante: 'info', texto: 'Servidor e banco de dados funcionando.' },
  banco_indisponivel: {
    variante: 'atencao',
    texto: 'O servidor respondeu, mas o banco de dados está indisponível.',
  },
  api_indisponivel: {
    variante: 'erro',
    texto: 'Servidor indisponível: sem resposta da API.',
  },
} as const;

/** Estado de GET /saude, anunciado ao leitor de tela pela região role="status". */
export function EstadoApi() {
  const [estado, setEstado] = useState<Estado>('verificando');

  useEffect(() => {
    const controle = new AbortController();
    consultarSaude({ sinal: controle.signal }).then(setEstado, () => {
      // Só rejeita quando o componente desmontou: nada a fazer.
    });
    return () => {
      controle.abort();
    };
  }, []);

  const { variante, texto } = mensagens[estado];
  return (
    <div role="status">
      <CartaoAviso variante={variante} titulo="Conexão com o servidor">
        {texto}
      </CartaoAviso>
    </div>
  );
}
