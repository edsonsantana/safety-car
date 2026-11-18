import tailwindcss from '@tailwindcss/vite';
import react from '@vitejs/plugin-react';
import { loadEnv } from 'vite';
import { defineConfig } from 'vitest/config';

// O .env fica na raiz do repositório, como na API. Só as variáveis VITE_* vão
// para o navegador; as demais (inclusive senhas) ficam apenas aqui na configuração.
const DIRETORIO_ENV = '../..';

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, DIRETORIO_ENV, '');
  const apiUrlDev = env.API_URL_DEV ?? 'http://127.0.0.1:3000';

  return {
    envDir: DIRETORIO_ENV,
    plugins: [react(), tailwindcss()],
    server: {
      host: '127.0.0.1',
      proxy: {
        // /api/saude -> http://127.0.0.1:3000/saude (mesma origem, sem CORS)
        '/api': {
          target: apiUrlDev,
          changeOrigin: true,
          rewrite: (caminho) => caminho.replace(/^\/api/, ''),
        },
      },
    },
    test: {
      environment: 'jsdom',
      setupFiles: ['./src/testes/configuracao.ts'],
      include: ['src/**/*.test.{ts,tsx}'],
      restoreMocks: true,
      unstubGlobals: true,
      // O Vitest esvazia o CSS por padrão; o teste de contraste lê o estilos.css?raw.
      css: { include: [/estilos\.css/] },
    },
  };
});
