import { BrowserRouter } from 'react-router';
import { lerConfigKeycloak } from './autenticacao/config.ts';
import { criarServicoOidc, type ServicoAutenticacao } from './autenticacao/oidc.ts';
import { ProvedorSessao } from './autenticacao/ProvedorSessao.tsx';
import { Rotas } from './Rotas.tsx';

const config = lerConfigKeycloak();

// Um único gerenciador OIDC por página (criado na primeira renderização).
let servicoPadrao: ServicoAutenticacao | undefined;
function obterServicoPadrao(): ServicoAutenticacao {
  servicoPadrao ??= criarServicoOidc(config);
  return servicoPadrao;
}

interface Props {
  /** Os testes trocam o Keycloak por um falso. */
  servico?: ServicoAutenticacao;
}

export function App({ servico }: Props) {
  return (
    <ProvedorSessao
      servico={servico ?? obterServicoPadrao()}
      cadastroHabilitado={config.cadastroHabilitado}
    >
      <BrowserRouter>
        <Rotas />
      </BrowserRouter>
    </ProvedorSessao>
  );
}
