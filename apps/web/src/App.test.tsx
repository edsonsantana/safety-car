import { render, screen } from '@testing-library/react';
import { expect, test, vi } from 'vitest';
import { App } from './App.tsx';

test('a aplicação abre na página inicial, com o estado da API', async () => {
  vi.stubGlobal('fetch', () =>
    Promise.resolve(new Response(JSON.stringify({ status: 'ok', banco: 'ok' }), { status: 200 })),
  );
  render(<App />);
  expect(screen.getByRole('heading', { level: 1, name: 'Início' })).toBeInTheDocument();
  expect(await screen.findByText('Servidor e banco de dados funcionando.')).toBeInTheDocument();
});
