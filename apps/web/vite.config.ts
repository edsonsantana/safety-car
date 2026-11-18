import tailwindcss from '@tailwindcss/vite';
import react from '@vitejs/plugin-react';
import { defineConfig } from 'vitest/config';

export default defineConfig({
  plugins: [react(), tailwindcss()],
  test: {
    environment: 'jsdom',
    setupFiles: ['./src/testes/configuracao.ts'],
    include: ['src/**/*.test.{ts,tsx}'],
    restoreMocks: true,
    // O Vitest esvazia o CSS por padrão; o teste de contraste lê o estilos.css?raw.
    css: { include: [/estilos\.css/] },
  },
});
