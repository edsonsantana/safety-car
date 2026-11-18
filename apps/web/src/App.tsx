import logotipo from './assets/logotipo-96.png';

export function App() {
  return (
    <main className="mx-auto flex max-w-[390px] flex-col items-center gap-4 p-6 font-sans">
      <img src={logotipo} alt="" width={96} height={96} />
      <h1 className="text-2xl font-bold text-marinho">Safety Car</h1>
    </main>
  );
}
