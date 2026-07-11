#!/bin/bash
set -e

# Cria o schema da tabela de api_keys
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -f /docker-entrypoint-initdb.d/auth-schema.sql

# Insere uma chave de dev pré-conhecida para uso local
# Chave plaintext: tm_key_local_dev
# O hash SHA-256 é calculado via sha256sum (disponível no Alpine)
DEV_KEY_HASH=$(echo -n "tm_key_local_dev" | sha256sum | awk '{print $1}')

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    INSERT INTO api_keys (name, key_hash)
    VALUES ('dev-local', '${DEV_KEY_HASH}')
    ON CONFLICT (key_hash) DO NOTHING;
EOSQL

echo ">>> Auth DB inicializado. Dev API Key: tm_key_local_dev"
