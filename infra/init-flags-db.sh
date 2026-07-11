#!/bin/bash
set -e

# Cria os bancos de dados separados para flag-service e targeting-service
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "postgres" <<-EOSQL
    CREATE DATABASE flags_db;
    CREATE DATABASE targeting_db;
EOSQL

# Inicializa o schema do flags_db
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "flags_db" \
  -f /docker-entrypoint-initdb.d/flags-schema.sql

# Inicializa o schema do targeting_db
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "targeting_db" \
  -f /docker-entrypoint-initdb.d/targeting-schema.sql

echo ">>> Flags DB e Targeting DB inicializados."
