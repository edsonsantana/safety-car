// Página da renovação silenciosa (iframe oculto, prompt=none): só devolve a resposta do
// Keycloak para a janela do app, que faz a troca do código pelo token.
import { UserManager } from 'oidc-client-ts';
import { lerConfigKeycloak } from './autenticacao/config.ts';
import { opcoesOidc } from './autenticacao/oidc.ts';

void new UserManager(opcoesOidc(lerConfigKeycloak(), window.location.origin))
  .signinSilentCallback()
  .catch(() => {
    // Nada a mostrar: a janela do app trata a falha (tempo esgotado) como "sem sessão".
  });
