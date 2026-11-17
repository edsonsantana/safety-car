# Safety Car

Plataforma de assistência rodoviária conectada (guincho, mecânica e serviços correlatos). Contexto, terminologia e regras do projeto estão em [`CLAUDE.md`](CLAUDE.md).

## Banco de dados local

PostgreSQL 16 + PostGIS em Docker. O `psql` roda dentro do contêiner, então nada é instalado no computador. No Windows, use o Git Bash. Documentação completa: [`docs/BANCO_DE_DADOS.md`](docs/BANCO_DE_DADOS.md).

```bash
cp .env.example .env          # troque TODOS os valores por senhas fortes (.env não vai para o Git)
docker compose up -d          # sobe o banco
docker compose ps             # espere o status "healthy"
bash db/scripts/migrar.sh     # aplica as migrações no banco "safetycar"
bash db/scripts/testar.sh     # recria "safetycar_teste" do zero e roda todos os testes
```

Conexão a partir do computador: `127.0.0.1:5432` (ou `DB_PORTA`), banco `safetycar`, usuário `safetycar_app` e a senha do `.env`.

Para recomeçar do zero (**apaga os dados locais**): `docker compose down -v` e depois `docker compose up -d`.
