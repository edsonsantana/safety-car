// Ponto de entrada. Etapa 1: só confirma que o TypeScript roda direto no Node.
// O servidor HTTP entra na etapa 2.
import { NOME_SERVICO } from './identidade.ts';

process.stdout.write(`${NOME_SERVICO}: esqueleto pronto (sem servidor HTTP ainda)\n`);
